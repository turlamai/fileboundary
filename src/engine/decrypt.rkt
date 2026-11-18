#lang racket/base

;; E-SafeNet wrapper decryption engine (T0 break, ADR-0006 mandate).
;;
;; Measured model (research/t0/README.md): the whole file is XORed with a
;; 512-byte repeating pad keyed by absolute file offset; the wrapper
;; overwrites the first zone+tail (=512) bytes with its own header +
;; metadata zone; under the pad the body is a zip whose first local header
;; is stripped (CD keeps lho=0, its data survives as a raw-deflate blob in
;; the metadata zone). All compression is standard dictionary-free deflate.
;;
;; Read-only guarantee: originals are never modified; decrypted output
;; goes only where the caller directs.

(require json
         racket/file
         racket/list
         racket/path
         racket/port
         racket/string
         file/gunzip
         "sha256.rkt")

(provide bytes-find find-xref-table
         load-pad
         xor-pad
         parse-wrapper
         crc32-bytes
         le16 le32
         find-cd
         inflate-raw
         verify-entry
         rebuild-ooxml-bytes
         decrypt-ooxml
         decrypt-zip
         decrypt-pdf
         salvage-objects
         extract-objstm
         twin-vote
         write-twin-pad
         decrypt-file)

;; ---------- small helpers ----------

(define (le16 b o)
  (+ (bytes-ref b o) (* 256 (bytes-ref b (+ o 1)))))

(define (le32 b o)
  (+ (bytes-ref b o)
     (* 256 (bytes-ref b (+ o 1)))
     (* 65536 (bytes-ref b (+ o 2)))
     (* 16777216 (bytes-ref b (+ o 3)))))

(define (u16->bytes n) (integer->integer-bytes n 2 #f #f))
(define (u32->bytes n) (integer->integer-bytes n 4 #f #f))

(define re-eocd (byte-regexp #"PK\x05\x06"))
(define re-cd (byte-regexp #"PK\x01\x02"))
(define re-lfh (byte-regexp #"PK\x03\x04"))
(define re-rec-num #px#"^[0-9]{1,6} 0 obj")
;; page / page-tree detection MUST accept the spaced canonical dict
;; form ("/Type /Page") as well as the unspaced one. A plain
;; byte-regexp gives \s no whitespace meaning (it degrades to a
;; literal "s" — the field failure behind "no direct page objects
;; found" on spaced producers), so these must stay pregexp patterns.
(define re-page (byte-pregexp #"/Type\\s*/Page(?![s])"))
(define re-pages (byte-pregexp #"/Type\\s*/Pages"))

;; 'xref\r\n0 <count>\r\n' located by scanning 'xref' anchors and
;; hand-checking the header bytes (control bytes stay out of regex
;; patterns: byte-regexp with embedded CR LF miscompiles on large inputs)
(define (find-xref-table s [start 0])
  (for/first ([m (in-list (regexp-match-positions* (byte-regexp #"xref")
                                                   s start))]
              #:when (let* ([o (car m)]
                            [n (bytes-length s)]
                            [header-ok
                             (and (<= (+ o 8) n)
                                  (= (bytes-ref s (+ o 4)) 13)
                                  (= (bytes-ref s (+ o 5)) 10)
                                  (= (bytes-ref s (+ o 6)) 48)
                                  (= (bytes-ref s (+ o 7)) 32))])
                       (and header-ok
                            (let loop ([i (+ o 8)] [acc 0])
                              (cond [(>= i n) #f]
                                    [(= (bytes-ref s i) 13) (> acc 0)]
                                    [(and (<= 48 (bytes-ref s i))
                                          (<= (bytes-ref s i) 57))
                                     (loop (+ i 1)
                                           (+ (* acc 10)
                                              (- (bytes-ref s i) 48)))]
                                    [else #f])))))
    (let* ([o (car m)]
           [count
            (let loop ([i (+ o 8)] [acc 0])
              (if (= (bytes-ref s i) 13)
                  acc
                  (loop (+ i 1) (+ (* acc 10) (- (bytes-ref s i) 48)))))])
      ;; records start after the count's own CRLF terminator
      (cons count
            (+ o 8
               (let loop ([i (+ o 8)] [d 0])
                 (if (= (bytes-ref s i) 13) d (loop (+ i 1) (add1 d))))
               2)))))

(define (bytes-find hay pat [start 0])
  (define m (regexp-match-positions pat hay start))
  (and m (car (car m))))

;; ---------- CRC32 (zip entry verification) ----------

(define crc32-table
  (let ([t (make-vector 256 0)])
    (for ([i (in-range 256)])
      (let loop ([c i] [k 0])
        (cond [(= k 8) (vector-set! t i c)]
              [(odd? c) (loop (bitwise-xor 3988292384
                                           (arithmetic-shift c -1))
                              (add1 k))]
              [else (loop (arithmetic-shift c -1) (add1 k))])))
    t))

(define (crc32-bytes b)
  (bitwise-xor
   4294967295
   (for/fold ([crc 4294967295])
             ([x (in-bytes b)])
     (bitwise-and
      4294967295
      (bitwise-xor (arithmetic-shift crc -8)
                   (vector-ref crc32-table
                               (bitwise-and 255 (bitwise-xor crc x))))))))

;; ---------- pad ----------

(define jnull (json-null))

;; load a pad JSON ({pad: [byte|null x512]}); missing columns omitted
(define (load-pad path)
  (define j (with-input-from-file path read-json))
  (for/hash ([v (in-list (hash-ref j 'pad))]
             [c (in-naturals)]
             #:unless (eq? v jnull))
    (values c v)))

(define (hex2 b)
  (define s (number->string b 16))
  (if (< b 16) (string-append "0" s) s))

;; best-effort guess at the content behind a bad magic: tells the
;; operator whether they picked a file that needs no decryption at all
(define (content-hint ct)
  (cond ((and (>= (bytes-length ct) 5)
              (bytes=? (subbytes ct 0 5) #"%PDF-"))
         " (this looks like an unencrypted PDF; decryption is not needed)")
        ((and (>= (bytes-length ct) 4)
              (bytes=? (subbytes ct 0 4) #"PK\x03\x04"))
         " (this looks like a plain zip/OOXML container; decryption is not needed)")
        (else "")))

;; Known wrapper magics. `62 14 23 65` is the measured family A
;; (bytes 4-5 = pre-body zone, 6-7 = zone tail, zone+tail = 512).
;; `64 14 23 65` is variant B, seen in the field (2026-11-06): bytes
;; 4-7 read as a plausible unix timestamp instead, so the header
;; layout differs — but the family signature (bytes 1-3) is intact
;; and the body encryption is expected to follow the same policy pad.
;; `63 14 23 65` is variant C, seen in the field (2026-11-09): bytes
;; 4-5 = 21, bytes 6-7 = 491, zone+tail = 512 — family-A geometry with
;; a different first byte. parse-wrapper accepts all three and lets
;; the body pipeline validate.
(define wrapper-magics
  (list #"\x62\x14\x23\x65" #"\x63\x14\x23\x65" #"\x64\x14\x23\x65"))

(define (parse-wrapper ct)
  (unless (>= (bytes-length ct) 8)
    (error 'parse-wrapper "file too short"))
  (unless (member (subbytes ct 0 4) wrapper-magics)
    (error 'parse-wrapper
           "not an E-SafeNet wrapper (bad magic): file starts with ~a, size ~a bytes~a"
           (string-join
            (for/list ((b (in-bytes (subbytes ct 0 16)))) (hex2 b))
            " ")
           (bytes-length ct)
           (content-hint ct)))
  (values (le16 ct 4) (le16 ct 6)))

(define (xor-pad ct pad)
  (define pat (make-bytes 512))
  (for ([c (in-range 512)])
    (bytes-set! pat c (hash-ref pad c 0)))
  (define n (bytes-length ct))
  (define out (make-bytes n))
  (for ([base (in-range 0 n 512)])
    (define span (min 512 (- n base)))
    (for ([i (in-range span)])
      (bytes-set! out (+ base i)
                  (bitwise-xor (bytes-ref ct (+ base i))
                               (bytes-ref pat i)))))
  out)

;; ---------- zip container handling ----------

(define (parse-cd s cd-off n-total)
  (let loop ([o cd-off] [acc '()] [left n-total])
    (cond [(zero? left) (values (reverse acc) o)]
          [(> (+ o 46) (bytes-length s))
           (error 'parse-cd "truncated CD entry at ~a" o)]
          [(not (bytes=? (subbytes s o (+ o 4)) #"PK\x01\x02"))
           (error 'parse-cd "bad CD entry magic at ~a" o)]
          [else
           (define e (hash 'ver-need (le16 s (+ o 6))
                           'flags (le16 s (+ o 8))
                           'method (le16 s (+ o 10))
                           'mtime (le16 s (+ o 12))
                           'mdate (le16 s (+ o 14))
                           'crc (le32 s (+ o 16))
                           'csize (le32 s (+ o 20))
                           'usize (le32 s (+ o 24))
                           'name (subbytes s (+ o 46)
                                           (+ o 46 (le16 s (+ o 28))))
                           'lho (le32 s (+ o 42))
                           'tail (+ (le16 s (+ o 30)) (le16 s (+ o 32)))))
           (loop (+ o 46 (bytes-length (hash-ref e 'name))
                    (hash-ref e 'tail))
                 (cons e acc) (sub1 left))])))

;; locate EOCD + CD; stored offset first, chain-walk fallback when pad
;; columns corrupted the stored fields. Returns (values eocd entries n)
(define (find-cd s)
  (define n (bytes-length s))
  (define win (max 0 (- n 65536)))
  ;; EOCD is addressed by the position of its 'PK' signature
  ;; (fields are relative to the signature start, as in any zip reader)
  (define eocd
    (for/first ([m (in-list (reverse
                              (regexp-match-positions* re-eocd s win n)))]
                #:when (<= (+ (car m) 22) n))
      (car m)))
  (unless eocd (error 'find-cd "no EOCD under this pad"))
  (define n-total (le16 s (+ eocd 10)))
  (define (try-at off)
    (with-handlers ([exn:fail? (lambda _ #f)])
      (define-values (entries end) (parse-cd s off n-total))
      (and (= end eocd) entries)))
  (define entries
    (or (try-at (le32 s (+ eocd 16)))
        (for/first ([m (in-list (reverse
                                 (regexp-match-positions* re-cd s 0 eocd)))]
                    #:when (try-at (car m)))
          (try-at (car m)))))
  (unless entries (error 'find-cd "no valid CD chain under this pad"))
  (values eocd entries n-total))

;; inflate a raw deflate stream (file/gunzip's inflate is raw-deflate,
;; exactly the zip entry format); CRC/length gates live in verify-entry
(define (inflate-raw data crc usize)
  (define out (open-output-bytes))
  (inflate (open-input-bytes data) out)
  (get-output-bytes out))

(define (entry-data-span s e)
  (define li (hash-ref e 'lho))
  (define nl (le16 s (+ li 26)))
  (define el (le16 s (+ li 28)))
  (values (+ li 30 nl el) (+ li 30 nl el (hash-ref e 'csize))))

;; inflate + length + CRC gate for one entry; blob overrides the data
;; span (used for the stripped first entry)
(define (verify-entry s e [blob #f])
  (with-handlers ([exn:fail? (lambda (exn)
                               (hash 'ok #f 'why (exn-message exn)))])
    (define data
      (or blob
          (let-values ([(a b) (entry-data-span s e)])
            (subbytes s a b))))
    (define out
      (case (hash-ref e 'method)
        [(8) (inflate-raw data (hash-ref e 'crc) (hash-ref e 'usize))]
        [(0) data]
        [else (error 'verify-entry "unsupported method ~a"
                     (hash-ref e 'method))]))
    (cond [(not (= (bytes-length out) (hash-ref e 'usize)))
           (hash 'ok #f 'why "length mismatch")]
          [(not (= (crc32-bytes out) (hash-ref e 'crc)))
           (hash 'ok #f 'why "crc mismatch")]
          [else (hash 'ok #t 'why "" 'data out)])))

;; ---------- header-zone entry recovery (plain-zip flavor) ----------

;; The wrapper destroys exactly the file's first 512 bytes (the wrapper
;; header replaces them one-to-one; no original head byte survives in
;; the file). An entry whose local header sits inside the zone but whose
;; DATA starts at or after the zone lost nothing but that local header,
;; and the central directory still carries every field it carried except
;; the name/extra lengths: the name length comes from the CD record, and
;; the extra length is recovered by trying candidates gated by the
;; entry's own method/CRC/usize. Written zips lay entries back-to-back,
;; so the next surviving local header pins the exact data end and yields
;; the first, exact candidate. An entry whose data starts inside the
;; zone (its stream head is physically gone) or whose candidates all
;; fail the gate stays lost; content is never fabricated.
(define zone-limit 512)

;; one candidate data span, gated by the entry's own integrity triple;
;; a span reaching into the destroyed zone can never be tried
(define (try-zone-entry-span s e start)
  (and (>= start zone-limit)
       (<= (+ start (hash-ref e 'csize)) (bytes-length s))
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define data (subbytes s start (+ start (hash-ref e 'csize))))
         (define out
           (case (hash-ref e 'method)
             [(8) (inflate-raw data (hash-ref e 'crc) (hash-ref e 'usize))]
             [(0) data]
             [else #f]))
         (and out
              (= (bytes-length out) (hash-ref e 'usize))
              (= (crc32-bytes out) (hash-ref e 'crc))
              out))))

;; recovered plaintext bytes for a header-zone entry, or #f
(define (recover-header-zone-data s e next-e)
  (define lho (hash-ref e 'lho))
  (define base (+ lho 30 (bytes-length (hash-ref e 'name))))
  (define csize (hash-ref e 'csize))
  ;; exact candidate: back-to-back layout - the next entry's surviving
  ;; local header sits where this entry's data ended
  (define derived
    (and next-e
         (let ([next-lho (hash-ref next-e 'lho)])
           (and (>= next-lho zone-limit)
                (let ([extra (- next-lho base csize)])
                  (and (<= 0 extra 65535) (+ base extra)))))))
  ;; bounded sweep of plausible local extra lengths: 0 first (every
  ;; mainstream writer), then 1..255. Zone giants skip the sweep so the
  ;; work stays bounded (a few hundred inflations of a huge entry
  ;; would not).
  (define sweep
    (if (> csize 4194304)
        (list base)
        (for/list ([extra (in-range 256)]) (+ base extra))))
  (define candidates (if derived (cons derived sweep) sweep))
  (for/or ([start (in-list candidates)])
    (try-zone-entry-span s e start)))

;; ---------- OOXML rebuild ----------

;; fresh local headers (extra = 0) + verbatim deflate data + fresh CD and
;; EOCD; the stripped first entry stores its raw deflate blob. Header-zone
;; entries (variant layouts) whose local data was overwritten by wrapper
;; metadata are emitted as STORED placeholders: docProps metadata gets a
;; minimal valid XML doc, directory entries stay empty — never document
;; content.
(define placeholder-xml-bytes
  (string->bytes/utf-8 "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Properties/>"))

(define (rebuild-ooxml-bytes s entries first-blob
                             [replacements (hasheq)] [omit null])
  ;; replacements: name-bytes -> plaintext bytes — the entry is emitted
  ;; STORED (method 0) with recomputed crc/sizes (nested-decrypted
  ;; content). omit: name-bytes dropped entirely (header-zone content
  ;; that no longer exists in the file — plain-zip semantics).
  (define kept
    (for/list ([e (in-list entries)]
               #:unless (member (hash-ref e 'name) omit))
      e))
  (define first (car entries))
  (define out (open-output-bytes))
  (define offs (make-hash))
  (define pos 0)
  ;; per-entry resolved values, reused by the CD loop below
  (define resolved (make-hash))
  (for ([e kept])
    (define lho (hash-ref e 'lho))
    (define is-first (< lho 512))
    (define is-dir (zero? (hash-ref e 'csize)))
    (define name (hash-ref e 'name))
    (define replacement (hash-ref replacements name #f))
    (define-values (data crc csize usize method)
      (cond
        ;; nested-decrypted content: stored plaintext, recomputed gates
        [replacement
         (values replacement (crc32-bytes replacement)
                 (bytes-length replacement) (bytes-length replacement)
                 0)]
        ;; stripped first entry (classic layout): its data is the blob
        ;; found near offset 512 — identified by CD name match with the
        ;; entry at the surviving local header
        [(and is-first first-blob
              (bytes-find s re-lfh 512)
              (equal? name
                      (hash-ref first 'name)))
         (values first-blob (hash-ref first 'crc)
                 (hash-ref first 'csize) (hash-ref first 'usize)
                 (hash-ref first 'method))]
        ;; header-zone entry: data overwritten by wrapper metadata —
        ;; stored placeholder (docProps metadata; directory entries stay
        ;; empty). Content entries never live in the header zone in
        ;; measured layouts.
        [is-first
         (if is-dir
             (values #"" 0 0 0 0)
             (values placeholder-xml-bytes
                     (crc32-bytes placeholder-xml-bytes)
                     (bytes-length placeholder-xml-bytes)
                     (bytes-length placeholder-xml-bytes)
                     0))]
        ;; intact entries: verbatim deflate data from the body
        [else
         (let*-values ([(a b) (entry-data-span s e)])
           (values (subbytes s a b) (hash-ref e 'crc)
                   (hash-ref e 'csize) (hash-ref e 'usize)
                   (hash-ref e 'method)))]))
    (hash-set! resolved name (hash 'crc crc 'csize csize 'usize usize
                                   'method method))
    (hash-set! offs name pos)
    (write-bytes (bytes-append #"PK\x03\x04"
                                   (u16->bytes (hash-ref e 'ver-need))
                                   (u16->bytes (hash-ref e 'flags))
                                   (u16->bytes method)
                                   (u16->bytes (hash-ref e 'mtime))
                                   (u16->bytes (hash-ref e 'mdate))
                                   (u32->bytes crc)
                                   (u32->bytes csize)
                                   (u32->bytes usize)
                                   (u16->bytes (bytes-length name))
                                   (u16->bytes 0)
                                   name data) out)
    (set! pos (+ pos 30 (bytes-length name) (bytes-length data))))
  (define cd-start pos)
  (for ([e kept])
    (define name (hash-ref e 'name))
    (define r (hash-ref resolved name))
    ;; full 46-byte CD record: a malformed stride (or a cd_size of 0)
    ;; passes tolerant scanners but breaks strict readers, so the record
    ;; layout and the running position must both be exact
    (write-bytes (bytes-append #"PK\x01\x02"
                                   (u16->bytes 20)
                                   (u16->bytes (hash-ref e 'ver-need))
                                   (u16->bytes (hash-ref e 'flags))
                                   (u16->bytes (hash-ref r 'method))
                                   (u16->bytes (hash-ref e 'mtime))
                                   (u16->bytes (hash-ref e 'mdate))
                                   (u32->bytes (hash-ref r 'crc))
                                   (u32->bytes (hash-ref r 'csize))
                                   (u32->bytes (hash-ref r 'usize))
                                   (u16->bytes (bytes-length name))
                                   (u16->bytes 0)   ; extra field length
                                   (u16->bytes 0)   ; comment length
                                   (u16->bytes 0)   ; disk number start
                                   (u16->bytes 0)   ; internal attributes
                                   (u32->bytes 0)   ; external attributes
                                   (u32->bytes (hash-ref offs name))
                                   name) out)
    (set! pos (+ pos 46 (bytes-length name))))
  (define cd-size (- pos cd-start))
  (write-bytes (bytes-append #"PK\x05\x06"
                                 (u16->bytes 0) (u16->bytes 0)
                                 (u16->bytes (length kept))
                                 (u16->bytes (length kept))
                                 (u32->bytes cd-size)
                                 (u32->bytes cd-start)
                                 (u16->bytes 0)) out)
  (get-output-bytes out))

;; family magic sniff for entry payloads: any known wrapper variant
(define (wrapped-bytes? b)
  (and (>= (bytes-length b) 4)
       (member (subbytes b 0 4) wrapper-magics) #t))

(define content-types-marker (string->bytes/utf-8 "[Content_Types].xml"))
;; hostile nesting guard: a zip inside a zip inside a zip …
(define zip-depth-limit 4)

(define (zip-container? s)
  (with-handlers ([exn:fail? (lambda _ #f)])
    (define-values (_e _entries _n) (find-cd s))
    #t))

;; decrypt one nested-wrapped entry payload to plaintext: containers
;; recurse through decrypt-zip (bounded depth), PDFs go through the PDF
;; pipeline, and anything else is an honest bounded failure — the
;; output zip never ships a member that is still wrapped.
(define (decrypt-nested-entry name-bytes inner-ct pad depth)
  (define display-name (bytes->string/utf-8 name-bytes #\?))
  (when (> (add1 depth) zip-depth-limit)
    (error 'decrypt-zip
           "nested archive depth exceeds ~a at ~a"
           zip-depth-limit display-name))
  (define inner-s (xor-pad inner-ct pad))
  (cond
    [(zip-container? inner-s)
     (define r (decrypt-zip inner-ct pad (add1 depth)))
     (values (hash-ref r 'bytes) (hash-ref r 'kind))]
    [(with-handlers ([exn:fail? (lambda _ #f)])
       (decrypt-pdf inner-ct pad))
     => (lambda (r) (values (hash-ref r 'bytes) "pdf"))]
    [else
     (error 'decrypt-zip
            "wrapped entry \"~a\": inner type is neither a zip container nor a PDF"
            display-name)]))

;; wrapped-zip container decryptor — the one machine behind the OOXML
;; path too (an OOXML file IS a zip). Two measured E-SafeNet layouts:
;;  - classic: first entry's local header is stripped, its deflate blob
;;    survives near offset 512, later entries are intact
;;  - header-zone variant: the first 512 bytes cover the local headers
;;    (+ data) of the leading entries; the CD at the tail survives.
;; Header-zone handling differs by flavor:
;;  - 'ooxml (the measured OOXML layout): header-zone entries carry
;;    docProps metadata, never document content — rebuilt as stored
;;    placeholders, counted as rebuilt
;;  - 'zip: header-zone directories survive as empty entries; header-zone
;;    CONTENT bytes exist nowhere in the file (E-SafeNet restores them
;;    only through its read-time driver), so they are reported as lost
;;    and omitted — a corrupt placeholder would be worse than absence
;; Entries whose plaintext starts with a wrapper magic are themselves
;; E-SafeNet-wrapped files: they are decrypted in the same pass
;; (nested containers recurse, bounded) and re-emitted as stored
;; plaintext with recomputed CRC gates.
(define (decrypt-zip ct pad [depth 0] [flavor #f])
  (define s (xor-pad ct pad))
  (define-values (_eocd entries _n) (find-cd s))
  (define first (car entries))
  (define first-pk (bytes-find s re-lfh 512))
  (define blob
    (and first-pk
         (subbytes s (- first-pk (hash-ref first 'csize)) first-pk)))
  (define resolved-flavor
    (or flavor
        (if (for/or ([e (in-list entries)])
              (bytes-find (hash-ref e 'name) content-types-marker))
            'ooxml
            'zip)))
  (define ooxml? (eq? resolved-flavor 'ooxml))
  (define verified 0)
  (define rebuilt-count 0)
  (define recovered-count 0)
  (define replacements (make-hash))
  (define lost-names null)
  (define decrypted-inner 0)
  ;; the CD entry that follows each entry in write order: back-to-back
  ;; layout makes the next surviving local header the exact boundary
  (define next-of
    (for/hash ([e (in-list entries)] [i (in-naturals)])
      (values e (and (< i (sub1 (length entries)))
                     (list-ref entries (add1 i))))))
  (define report
    (for/list ([e entries])
      (define name-bytes (hash-ref e 'name))
      (define display-name (bytes->string/utf-8 name-bytes #\?))
      (define in-header-zone (< (hash-ref e 'lho) 512))
      (define is-dir (zero? (hash-ref e 'csize)))
      (define-values (v rebuilt? lost? wrapped inner-kind)
        (cond
          ;; header-zone entries: damage-based handling. Data past the
          ;; zone means only the local header is gone - rebuild it from
          ;; the CD, gated by the entry's own method/CRC/usize (field
          ;; report 2026-11-17: an owner-added member with lho < 512 was
          ;; dropped whole even though every content byte survived).
          ;; Data that starts inside the zone is physically gone:
          ;; reported lost, never fabricated.
          [(and in-header-zone (not ooxml?) (not is-dir))
           (define recovered
             (recover-header-zone-data s e (hash-ref next-of e)))
           (cond
             [(not recovered)
              (set! lost-names (cons name-bytes lost-names))
              (values #f #f #t #f #f)]
             [(wrapped-bytes? recovered)
              ;; a recovered member that is itself wrapped gets the same
              ;; same-pass nested decryption as any other member
              (define-values (plain inner-kind)
                (decrypt-nested-entry name-bytes recovered pad depth))
              (hash-set! replacements name-bytes plain)
              (set! decrypted-inner (add1 decrypted-inner))
              (set! recovered-count (add1 recovered-count))
              (values (hash 'ok #t) #f #f #t inner-kind)]
             [else
              (hash-set! replacements name-bytes recovered)
              (set! recovered-count (add1 recovered-count))
              (values (hash 'ok #t) #f #f #f #f)])]
          ;; OOXML measured layout: docProps metadata placeholders
          [in-header-zone
           (values (hash 'ok #t 'rebuilt #t) #t #f #f #f)]
          [else
           (define v (verify-entry s e #f))
           (cond
             [(not (hash-ref v 'ok)) (values v #f #f #f #f)]
             [(wrapped-bytes? (hash-ref v 'data))
              (define-values (plain inner-kind)
                (decrypt-nested-entry name-bytes (hash-ref v 'data)
                                      pad depth))
              (hash-set! replacements name-bytes plain)
              (set! decrypted-inner (add1 decrypted-inner))
              (values (hash 'ok #t) #f #f #t inner-kind)]
             [else (values v #f #f #f #f)])]))
      (when (and v (hash-ref v 'ok)) (set! verified (add1 verified)))
      (when rebuilt? (set! rebuilt-count (add1 rebuilt-count)))
      (hash 'name display-name
            'crcOk (and v (hash-ref v 'ok))
            'lost lost?
            'wrapped wrapped
            'innerKind inner-kind)))
  ;; CRC failures on verifiable entries still mean the pad does not
  ;; match; lost header-zone entries are expected and reported instead
  (define failed (- (length entries) verified (length lost-names)))
  (unless (zero? failed)
    (error 'decrypt-zip
           "only ~a/~a entries verified; pad does not match this file"
           verified (length entries)))
  (hash 'entries report
        'verified verified
        'total (length entries)
        'rebuiltEntries rebuilt-count
        'recoveredEntries recovered-count
        'lostEntries
        (reverse
         (for/list ([n (in-list lost-names)])
           (bytes->string/utf-8 n #\?)))
        'decryptedInner decrypted-inner
        'kind (if ooxml? "ooxml" "zip")
        'bytes (rebuild-ooxml-bytes s entries blob
                                    replacements lost-names)))

;; compat entry point: the OOXML flavor with the original report shape
;; (the returned hash is a superset of the old one)
(define (decrypt-ooxml ct pad)
  (decrypt-zip ct pad 0 'ooxml))

;; ---------- PDF rebuild ----------

(define (zero-pad10 n)
  (define str (number->string n))
  (string-append (make-string (- 10 (string-length str)) #\0) str))

;; xref-driven page enumeration (never crosses object boundaries)
(define (page-objects-from-xref s body-start)
  (define hdr (find-xref-table s body-start))
  (unless hdr (error 'decrypt-pdf "no classic xref table header"))
  (define count (car hdr))
  (define tstart (cdr hdr))
  (for/list ([k (in-range count)]
             #:when (let* ([rp (+ tstart (* 20 k))]
                           [rec-ok
                            (and (<= (+ rp 20) (bytes-length s))
                                 (= (bytes-ref
                                     (subbytes s rp (+ rp 20)) 17)
                                    (char->integer #\n)))]
                           [off
                            (and rec-ok
                                 (string->number
                                  (bytes->string/utf-8
                                   (subbytes s rp (+ rp 10)))))])
                      (and off
                           (>= off body-start)
                           (regexp-match? re-rec-num
                                          (subbytes s off (+ off 16)))
                           (let ([obj-end (or (bytes-find s #"endobj" off)
                                              off)])
                             (define seg
                               (subbytes s off
                                         (min (+ obj-end 6)
                                              (bytes-length s))))
                             (and (regexp-match? re-page seg)
                                  (not (regexp-match? re-pages seg))
                                  #t)))))
    k))

(define (decrypt-pdf ct pad)
  ;; dispatch: a classic xref table means the measured-family head
  ;; rebuild; anything else (xref streams, PDF 1.5+) goes to object
  ;; salvage into a fresh document skeleton. A correct pad leaves
  ;; readable PDF objects in the body — the wrapper header itself is
  ;; unencrypted, so without this check a wrong pad masqueraded as a
  ;; structural problem.
  (define s (xor-pad ct pad))
  (define body-start 512)
  (unless (>= (count-subbytes s body-start #" obj") 2)
    (error 'decrypt-pdf
           "the pad does not match this file: no recognizable PDF structures after decryption"))
  (if (find-xref-table s body-start)
      (decrypt-pdf-classic s body-start)
      (decrypt-pdf-salvage s body-start)))

;; ---------- classic rebuild: straddler prefix reconstruction ----------
;; v0.8.4: field reports (2026-11) showed the fixed page-prefix splice
;; is wrong for two real layouts — a page cut mid-reference inside its
;; /Resources sub-dictionaries rebuilt with an unbalanced prefix (the
;; first /MediaBox-less page rendered blank), and a pages-tree ROOT cut
;; mid-/Kids aborted with "straddling object is not a page". The prefix
;; is now rebuilt from the surviving tail's own structure instead of a
;; fixed splice, and the root layout heals via the xref page scan.

;; dict depth balance of a byte fragment: << opens, >> closes, literal
;; and hex strings are skipped so embedded payloads cannot skew the
;; count. A negative result means the tail closes more dictionaries
;; than it opens — that many dictionaries were hanging open at the cut.
(define (dict-balance b)
  (define n (bytes-length b))
  (let loop ([i 0] [d 0])
    (cond
      [(>= (+ i 1) n) d]
      ;; literal string: parens nest, backslash escapes
      [(= (bytes-ref b i) 40)
       (let paren ([j (add1 i)] [nest 1])
         (cond
           [(>= j n) (loop j d)]
           [(and (= (bytes-ref b j) 92) (< (+ j 1) n)) (paren (+ j 2) nest)]
           [(= (bytes-ref b j) 40) (paren (add1 j) (add1 nest))]
           [(= (bytes-ref b j) 41)
            (if (= nest 1) (loop (add1 j) d) (paren (add1 j) (sub1 nest)))]
           [else (paren (add1 j) nest)]))]
      [(= (bytes-ref b i) 60)
       (cond
         [(= (bytes-ref b (add1 i)) 60) (loop (+ i 2) (add1 d))]
         ;; lone '<': hex string, skip to its '>' terminator
         [else (loop (or (bytes-find b #">" (add1 i)) n) d)])]
      [(and (= (bytes-ref b i) 62) (= (bytes-ref b (add1 i)) 62))
       (loop (+ i 2) (sub1 d))]
      [else (loop (add1 i) d)])))

;; completion tokens so a DICT tail cut mid-value parses: dictionary
;; values are name->value entries, so the head supplies a fabricated
;; entry name plus, depending on where the cut fell inside an indirect
;; reference, the missing integers. The fabricated entry is unreferenced
;; by name — it only has to parse; the surviving entries keep theirs.
(define (page-tail-completion tail)
  (cond
    ;; "<gen> R" survived: supply name + object number
    [(regexp-match? #px#"^[ ]?[0-9]+[ ]R[ /]" tail) "/X 1 "]
    ;; "<obj> <gen> R" survived: supply the name only
    [(regexp-match? #px#"^[ ]?[0-9]+[ ][0-9]+[ ]R" tail) "/X "]
    ;; bare "R" survived: supply name + object number + generation
    [(regexp-match? #px#"^[ ]?R[ ]" tail) "/X 1 0 "]
    ;; a fresh name survived: the cut fell at an entry boundary
    [(regexp-match? #px#"^/" tail) ""]
    ;; any other value shape (number, array, string, hex, dict): give
    ;; it a name and let the tail supply the value
    [else "/X "]))

;; the orphan fragment's surviving entry names identify which /Resources
;; sub-dictionary the cut opened into (/GS* → ExtGState etc.); unknown
;; containers degrade to a neutral /G key — the fabricated level only
;; has to parse, and entries that content streams look up by name
;; (/GS14 etc.) stay reachable when the container key matches
(define (infer-resources-subkey tail)
  (cond
    [(regexp-match? #px#"/GS[0-9]" tail) "/ExtGState"]
    [(regexp-match? #px#"/F[0-9]" tail) "/Font"]
    [(regexp-match? #px#"/(Im|Image)[0-9]" tail) "/XObject"]
    [(regexp-match? #px#"/Cs[0-9]" tail) "/ColorSpace"]
    [else "/G"]))

;; pages-tree-root tail shape: a (possibly cut) run of kid references
;; closed by "] >>" then endobj — references only, no page keys
(define (pages-root-tail-shape tail)
  (define m (regexp-match-positions
             #px#"^[ ]?(?:[0-9]+[ ]R[ ]|R[ ])?(?:[0-9]+[ ]+0[ ]+R[ ]?)*\\]"
             tail))
  (and m
       (regexp-match? #px#"^[ ]?>>[ \r\n]*endobj" (subbytes tail (cdar m)))))

;; kid numbers visible in a root tail's reference run; a cut "<gen> R"
;; or bare "R" fragment never matches, so the cut kid is always in the
;; lost head by definition. Byte-regex captures come back as byte
;; strings, so decode before string->number.
(define (tail-kids tail)
  (map (lambda (b) (string->number (bytes->string/utf-8 b)))
       (regexp-match* #px#"([0-9]+)[ ]+0[ ]+R" tail #:match-select cadr)))

(define (decrypt-pdf-classic s body-start)
  (define hdr (find-xref-table s body-start))
  (unless hdr (error 'decrypt-pdf "no classic xref table header"))
  (define count (car hdr))
  (define tstart (cdr hdr))
  ;; the straddler is the LAST record with offset < body-start: earlier
  ;; low-offset objects were fully overwritten; this one's dict tail
  ;; survives from body-start (offsets increase monotonically)
  (define straddler-hit
    (for/fold ([hit #f])
              ([k (in-range count)]
               #:when (<= (+ tstart (* 20 k) 20) (bytes-length s)))
      (define rec (subbytes s (+ tstart (* 20 k))
                            (+ tstart (* 20 k) 20)))
      (if (and (= (bytes-ref rec 17) (char->integer #\n))
               (< (string->number (bytes->string/utf-8 (subbytes rec 0 10)))
                  body-start))
          (cons k (string->number (bytes->string/utf-8 (subbytes rec 0 10))))
          hit)))
  (unless straddler-hit
    (error 'decrypt-pdf "no object straddles the overwrite boundary"))
  (define straddler (car straddler-hit))
  (define straddler-off (cdr straddler-hit))
  ;; the rebuilt head is exactly as long as the straddler's xref offset,
  ;; so its record keeps pointing at the right place without patching
  (define head-prefix-len straddler-off)
  (define obj-end
    (or (bytes-find s #"endobj" body-start)
        (error 'decrypt-pdf "straddler endobj not found")))
  (define obj-end-abs (+ obj-end 8))
  (define straddler-tail (subbytes s body-start obj-end-abs))
  (define page-objects (page-objects-from-xref s body-start))
  ;; classify the straddler by its surviving tail: a page keeps
  ;; /Contents or /StructParents past the boundary; the pages-tree root
  ;; keeps a bare run of /Kids references closed by "] >>"
  (define page-tail?
    (or (regexp-match? #px#"/StructParents" straddler-tail)
        (regexp-match? #px#"/Contents" straddler-tail)))
  (define root-tail?
    (and (not page-tail?) (pages-root-tail-shape straddler-tail)))
  (unless (or page-tail? root-tail?)
    (error 'decrypt-pdf
           "straddling object tail is neither a page nor a pages tree"))
  ;; the rebuilt head lands the catalog and (page layout) the pages
  ;; tree at their original xref offsets, all below straddler-off —
  ;; the straddler must not collide with either
  (when (and page-tail? (< straddler 3))
    (error 'decrypt-pdf "straddling page collides with the rebuilt head objects"))
  (when (and root-tail? (< straddler 2))
    (error 'decrypt-pdf "straddling pages tree collides with the rebuilt catalog"))
  (when (and root-tail? (null? page-objects))
    (error 'decrypt-pdf "no page objects recoverable from the xref"))
  ;; ---- original offsets from the classic table ----
  ;; v0.8.4: the hybrid field files also carry an /XRefStm
  ;; cross-reference stream and an empty incremental-update table
  ;; (startxref -> "xref 0 0" + trailer). Readers that understand xref
  ;; streams resolve objects through THE STREAM, whose entries keep
  ;; the original offsets — patching only the classic table's records
  ;; leaves stream readers following the stale offset into the rebuilt
  ;; head, landing mid-token. The rebuild therefore lands every object
  ;; exactly where the original stood, so the classic table, the
  ;; stream and the output all agree and record patches fall away.
  (define (rec-offset k)
    (and (< k count)
         (let* ([rp (+ tstart (* 20 k))]
                [end (+ rp 20)])
           (and (<= end (bytes-length s))
                (let ([rec (subbytes s rp end)])
                  (and (= (bytes-ref rec 17) (char->integer #\n))
                       (string->number
                        (bytes->string/utf-8 (subbytes rec 0 10)))))))))
  (define orig1 (rec-offset 1))
  (define orig2 (rec-offset 2))
  (unless orig1
    (error 'decrypt-pdf "classic xref table has no in-use record for the catalog"))
  ;; the catalog is rebuilt only when its own record points into the
  ;; lost zone; a surviving catalog already references the right tree.
  ;; Same for the pages tree in the page layout (a surviving tree
  ;; already lists the straddler among its kids).
  (define catalog-lost? (< orig1 body-start))
  (define tree-lost?
    (and page-tail? (or (not orig2) (< orig2 body-start))))
  ;; straddler-prefix: the fabricated bytes landing at
  ;; straddler-off..body-start; tree-txt: the rebuilt pages tree (page
  ;; layout only); pages-count: report total
  (define-values (straddler-prefix tree-txt pages-count)
    (cond
      [page-tail?
       (let ()
         (define kids (cons straddler
                            (for/list ([k page-objects]
                                       #:unless (= k straddler))
                              k)))
         ;; how many dictionaries the cut left hanging open: 1 = page
         ;; keys survived, 2 = /Resources entries, 3 = inside a
         ;; /Resources sub-dictionary (recovered by its entry names)
         (define balance (- (dict-balance straddler-tail)))
         (unless (<= 1 balance 6)
           (error 'decrypt-pdf
                  "straddler page tail leaves ~a unmatched dictionaries"
                  balance))
         (define completion
           (string->bytes/utf-8 (page-tail-completion straddler-tail)))
         (define fixed
           (string->bytes/utf-8
            (string-append
             (format "~a 0 obj\r\n<</Type/Page/Parent 2 0 R" straddler)
             (if (>= balance 2) "/Resources<<" "")
             (if (>= balance 3)
                 (string-append (infer-resources-subkey straddler-tail) "<<")
                 "")
             (apply string-append
                    (for/list ([_ (in-range (max 0 (- balance 3)))])
                      "/G<<")))))
         (define fill (- (- body-start straddler-off)
                         (bytes-length fixed) (bytes-length completion)))
         (unless (>= fill 0)
           (error 'decrypt-pdf "no room for straddler prefix"))
         (values (bytes-append fixed (make-bytes fill (char->integer #\space))
                               completion)
                 (string->bytes/utf-8
                  (format "2 0 obj\n<</Type/Pages/Kids[~a]/Count ~a>>\nendobj\n"
                          (string-join
                           (for/list ([k kids]) (format "~a 0 R" k)) " ")
                          (length kids)))
                 (length kids)))]
      [else  ;; root-tail?: the straddler IS the pages tree root
       (let ()
         (define tkids (tail-kids straddler-tail))
         (unless (andmap (lambda (k) (member k page-objects)) tkids)
           (error 'decrypt-pdf
                  "straddler /Kids references objects that are not pages"))
         (define lost-kids
           (for/list ([k page-objects] #:unless (member k tkids)) k))
         ;; /Kids arrays are written in ascending object order, so the
         ;; lost head must sit entirely before the surviving tail —
         ;; anything else means the scan misread the array
         (when (and (pair? tkids) (pair? lost-kids)
                    (>= (apply max lost-kids) (apply min tkids)))
           (error 'decrypt-pdf
                  "lost /Kids entries do not precede the surviving ones"))
         (define lost-last (and (pair? lost-kids) (last lost-kids)))
         ;; completion for the kid reference the cut sliced: array
         ;; elements are positional, so only the missing integers of
         ;; the cut reference are supplied (its number comes from the
         ;; xref scan)
         (define completion-txt
           (cond
             [(regexp-match? #px#"^[ ]?R[ ]" straddler-tail)
              (unless lost-last
                (error 'decrypt-pdf
                       "cut /Kids reference has no recoverable object number"))
              (string-append (number->string lost-last) " 0 ")]
             [(regexp-match? #px#"^[ ]?[0-9]+[ ]R[ ]" straddler-tail)
              (unless lost-last
                (error 'decrypt-pdf
                       "cut /Kids reference has no recoverable object number"))
              (string-append (number->string lost-last) " ")]
             [else ""]))
         ;; the cut kid's head is completion-only; every OTHER lost kid
         ;; is re-emitted as a full reference
         (define head-lost-kids
           (if (string=? completion-txt "") lost-kids (drop-right lost-kids 1)))
         (define completion (string->bytes/utf-8 completion-txt))
         (define fixed
           (string->bytes/utf-8
            (string-append
             (format "~a 0 obj\r\n<</Type/Pages/Count ~a/Kids["
                     straddler (length page-objects))
             (apply string-append
                    (for/list ([k head-lost-kids]) (format "~a 0 R " k))))))
         (define fill (- (- body-start straddler-off)
                         (bytes-length fixed) (bytes-length completion)))
         (unless (>= fill 0)
           (error 'decrypt-pdf "no room for straddler prefix"))
         (values (bytes-append fixed (make-bytes fill (char->integer #\space))
                               completion)
                 #""
                 (length page-objects)))
                 ]))
  ;; ---- head zone: '#' filler with rebuilt objects at their
  ;; original offsets ----
  (define catalog-txt
    (string->bytes/utf-8
     (format "1 0 obj\n<< /Type /Catalog /Pages ~a 0 R >>\nendobj\n"
             (if page-tail? 2 straddler))))
  (define catalog-at (and catalog-lost? orig1))
  (when (and catalog-at (< orig1 9))
    (error 'decrypt-pdf "no room for the PDF header before the catalog"))
  (define catalog-end
    (if catalog-at (+ catalog-at (bytes-length catalog-txt)) 15))
  (define head-limit (- head-prefix-len 1))
  (when (and catalog-at (> catalog-end head-limit))
    (error 'decrypt-pdf "rebuilt catalog does not fit before the straddler"))
  ;; the rebuilt tree lands at ITS original offset when it fits there
  ;; without touching the catalog; otherwise right behind the catalog,
  ;; with record 2 patched to that fallback position
  (define tree-fits-orig?
    (and tree-lost? orig2
         (<= (+ orig2 (bytes-length tree-txt)) head-limit)
         (or (not catalog-at) (<= catalog-end orig2))))
  (define tree-at (if tree-fits-orig? orig2 catalog-end))
  (when (and tree-lost? (> (+ tree-at (bytes-length tree-txt)) head-limit))
    (error 'decrypt-pdf "rebuilt pages tree does not fit before the straddler"))
  (define patch-record-2? (and tree-lost? (not tree-fits-orig?)))
  (define head
    (make-bytes head-prefix-len (char->integer #\#)))
  (bytes-copy! head 0
               (if (and catalog-at (< orig1 15))
                   #"%PDF-1.4\n"
                   #"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n"))
  (when catalog-at (bytes-copy! head catalog-at catalog-txt))
  (when tree-lost? (bytes-copy! head tree-at tree-txt))
  ;; a newline right before the straddler prefix keeps its first token
  ;; clean (kept only when the placement did not already end there)
  (when (= (bytes-ref head (- head-prefix-len 1)) (char->integer #\#))
    (bytes-set! head (- head-prefix-len 1) 10))
  ;; patch record 2 only when the tree had to fall back behind the
  ;; catalog; everything else already sits where its record says
  (define s2 (bytes-copy s))
  (for ([spec (if patch-record-2? (list (cons 2 tree-at)) '())]
        #:when (< (car spec) count))
    (define rp (+ tstart (* 20 (car spec))))
    (bytes-copy! s2 rp
                 (string->bytes/utf-8
                  (string-append (zero-pad10 (cdr spec)) " 00000 n\r\n"))))
  ;; assemble: head fills 0..head-prefix-len, the straddler prefix+filler
  ;; fills up to body-start, then the straddler tail and the rest
  (define original
    (bytes-append head
                  straddler-prefix
                  straddler-tail
                  (subbytes s2 obj-end-abs)))
  (unless (= (bytes-length original) (bytes-length s))
    (error 'decrypt-pdf "assembled length mismatch: ~a vs ~a"
           (bytes-length original) (bytes-length s)))
  ;; xref spot-check in the original coordinate system: walk every
  ;; classic table and verify each 'n' record's offset lands on an
  ;; object header. v0.8.4: the scan covers the whole document — the old
  ;; last-64KiB window silently skipped tables larger than 64 KiB (the
  ;; 4 005-entry field table starts ~80 KiB before EOF, so the check
  ;; verified nothing). Records >= 15 are checked: 15 is the rebuilt
  ;; catalog's offset, so this also validates the patched head records
  ;; and the straddler's own landing; an offset with no room for the
  ;; header probe counts as bad instead of crashing subbytes.
  (define checked 0)
  (define bad 0)
  (let loop-table ([search-from 0])
    (define hdr (find-xref-table original search-from))
    (when hdr
      (define t-count (car hdr))
      (define t-start (cdr hdr))
      (for ([k (in-range t-count)]
            #:when (<= (+ t-start (* 20 k) 20) (bytes-length original)))
        (define rp (+ t-start (* 20 k)))
        (define rec (subbytes original rp (+ rp 20)))
        (when (= (bytes-ref rec 17) (char->integer #\n))
          (define off
            (string->number (bytes->string/utf-8 (subbytes rec 0 10))))
          (when (and off (>= off 15))
            (set! checked (add1 checked))
            (unless (and (< (+ off 32) (bytes-length original))
                         (regexp-match? re-rec-num
                                        (subbytes original off (+ off 32))))
              (set! bad (add1 bad))))))
      (loop-table (+ t-start (* 20 t-count)))))
  (hash 'bytes original
        'xrefChecked checked
        'xrefBad bad
        'headRebuilt #t
        'coverObject straddler
        'pages pages-count))

;; ---------- non-classic xref salvage (xref-stream PDFs) ----------

;; occurrences of a byte pattern in s from `from` onward
(define (count-subbytes s from needle)
  (define n (bytes-length needle))
  (let loop ((i from) (c 0))
    (if (> (+ i n) (bytes-length s))
        c
        (loop (+ i 1)
              (+ c (if (bytes=? (subbytes s i (+ i n)) needle) 1 0))))))

;; collect intact top-level "N 0 obj ... endobj" objects from the
;; decrypted body: deduplicated by object number, non-overlapping
;; spans, stale xref streams and compressed object streams counted
;; separately (their contents cannot be salvaged here — but the xref
;; streams are returned as byte strings: their records are the
;; original document's authoritative object inventory, issue #62)
(define (salvage-objects s body-start)
  (define matches
    (sort
     (for/list ((m (in-list (regexp-match-positions* #px#"([0-9]{1,6}) 0 obj"
                                                     s body-start))))
       m)
     < #:key car))
  (define seen (make-hash))
  (define spans null)
  (define objstms 0)
  (define objstm-objs null)
  (define xref-objs null)
  ;; sanity for a captured span: real top-level objects open with a
  ;; dict or array, and endobj follows endstream (stream objects) or
  ;; >> (plain dicts). Binary noise inside large streams matches the
  ;; "N 0 obj" header pattern often enough to swallow real objects
  ;; through the seen/spans bookkeeping — these two checks kill that.
  (define (object-open-sane? start hdr-end)
    (define after (objstm-skip-ws s hdr-end))
    (and (< after (bytes-length s))
         (let ((c (bytes-ref s after)))
           (or (= c 60) (= c 91)))))
  (define (object-end-sane? obj-end)
    (let loop ((i (- obj-end 1)))
      (cond ((< i 9) #f)
            ((let ((c (bytes-ref s i))) (or (= c 10) (= c 13) (= c 32)))
             (loop (- i 1)))
            (else
             (or (bytes=? (subbytes s (- i 8) (+ i 1)) #"endstream")
                 (bytes=? (subbytes s (- i 1) (+ i 1)) #">>"))))))
  (for ((m (in-list matches)))
    (define start (car m))
    ;; a real object header is preceded by whitespace or a document
    ;; boundary; inside content streams the text is usually embedded
    ;; differently, but this stays a heuristic
    (define prev-ok (or (= start body-start)
                        (let ((p (bytes-ref s (sub1 start))))
                          (or (= p 10) (= p 13) (= p 32)))))
    (define num
      (string->number
       (bytes->string/utf-8
        (subbytes s (car m) (+ (car m) (- (cdr m) (car m) 6))))))
    (when (and prev-ok num (not (hash-has-key? seen num)))
      (define obj-end (bytes-find s #"endobj" (cdr m)))
      (when obj-end
        (define end-abs (min (+ obj-end 6) (bytes-length s)))
        ;; sanity: real top-level objects open with a dict/array and
        ;; endobj follows endstream or >>. Binary noise inside large
        ;; streams matches the "N 0 obj" header pattern often enough
        ;; to swallow real objects through seen/spans — these checks
        ;; kill that.
        (when (and (object-open-sane? start (cdr m))
                   (object-end-sane? obj-end))
          ;; non-overlap against the spans accepted so far (matches
          ;; are processed in ascending start order). The old check
          ;; added start+end together, which silently rejected every
          ;; object that followed a large one — salvage captured only
          ;; a handful of objects on real xref-stream documents.
          (when (for/and ((sp (in-list spans)))
                  (or (<= (cdr sp) start)
                      (>= (car sp) end-abs)))
            (set! spans (cons (cons start end-abs) spans))
            (define obj (subbytes s start end-abs))
            (cond
              ((regexp-match? #px"/Type\\s*/XRef\\b" obj)
               (set! xref-objs (cons obj xref-objs)))
              ((regexp-match? #px"/Type\\s*/ObjStm\\b" obj)
               (set! objstms (add1 objstms))
               (set! objstm-objs (cons obj objstm-objs)))
              (else (hash-set! seen num obj))))))))
  (values seen objstms objstm-objs xref-objs))

;; ---------- compressed object streams (PDF 1.5 ObjStm) ----------

;; inflate one zlib-format stream (2-byte header + raw deflate +
;; 4-byte adler32); try with the checksum tail, then without
(define (inflate-zlib data)
  (or (with-handlers ([exn:fail? (lambda _ #f)])
        (and (>= (bytes-length data) 3)
             (inflate-raw (subbytes data 2) #f #f)))
      (with-handlers ([exn:fail? (lambda _ #f)])
        (and (> (bytes-length data) 6)
             (inflate-raw (subbytes data 2 (- (bytes-length data) 4)) #f #f)))))

;; the stream payload of an object: between the keyword's EOL and
;; the matching "endstream"
(define (objstm-stream-data obj)
  (define sm (bytes-find obj #"stream"))
  (and sm
       (let ((len (bytes-length obj)))
         (define ds
           (cond ((and (< (+ sm 8) len)
                       (= (bytes-ref obj (+ sm 6)) 13)
                       (= (bytes-ref obj (+ sm 7)) 10))
                  (+ sm 8))
                 ((< (+ sm 7) len) (+ sm 7))
                 (else #f)))
         (and ds
              (let ((de (bytes-find obj #"endstream" ds)))
                (and de (subbytes obj ds de)))))))

;; scan one PDF value starting at o, returning the offset just past it
;; (dicts balance <</>>, arrays balance [], strings are skipped safely)
(define (objstm-scan-value buf o)
  (define len (bytes-length buf))
  (define b (bytes-ref buf o))
  (cond
    ((and (= b 60) (< (+ o 1) len) (= (bytes-ref buf (+ o 1)) 60))
     ;; << dict >>
     (let loop ((i (+ o 2)))
       (cond ((>= i len) len)
             ((and (= (bytes-ref buf i) 62)
                   (< (+ i 1) len)
                   (= (bytes-ref buf (+ i 1)) 62))
              (+ i 2))
             ((and (= (bytes-ref buf i) 60)
                   (< (+ i 1) len)
                   (= (bytes-ref buf (+ i 1)) 60))
              (loop (objstm-scan-value buf i)))
             ((= (bytes-ref buf i) 60)
              (loop (objstm-scan-hex-string buf i)))
             ((= (bytes-ref buf i) 40)
              (loop (objstm-scan-paren-string buf i)))
             (else (loop (+ i 1))))))
    ((= b 60) (objstm-scan-hex-string buf o))
    ((= b 40) (objstm-scan-paren-string buf o))
    ((= b 91)
     ;; [ array ]
     (let loop ((i (+ o 1)))
       (cond ((>= i len) len)
             ((= (bytes-ref buf i) 93) (+ i 1))
             ((= (bytes-ref buf i) 40)
              (loop (objstm-scan-paren-string buf i)))
             ((= (bytes-ref buf i) 60)
              (loop (objstm-scan-value buf i)))
             (else (loop (+ i 1))))))
    (else
     ;; scalar: number / name / keyword up to whitespace or delimiter
     (let loop ((i o))
       (cond ((>= i len) len)
             ((let ((c (bytes-ref buf i)))
                (or (= c 32) (= c 9) (= c 10) (= c 13)
                    (= c 47) (= c 60) (= c 91) (= c 40)))
              i)
             (else (loop (+ i 1))))))))

(define (objstm-scan-hex-string buf o)
  (define len (bytes-length buf))
  (let loop ((i (+ o 1)))
    (cond ((>= i len) len)
          ((= (bytes-ref buf i) 62) (+ i 1))
          (else (loop (+ i 1))))))

(define (objstm-scan-paren-string buf o)
  (define len (bytes-length buf))
  (let loop ((i (+ o 1)) (depth 1))
    (cond ((>= i len) len)
          ((= (bytes-ref buf i) 92) (loop (min len (+ i 2)) depth))
          ((= (bytes-ref buf i) 40) (loop (+ i 1) (add1 depth)))
          ((= (bytes-ref buf i) 41)
           (let ((d (sub1 depth)))
             (if (zero? d) (+ i 1) (loop (+ i 1) d))))
          (else (loop (+ i 1) depth)))))

(define (objstm-skip-ws buf o)
  (define len (bytes-length buf))
  (let loop ((i o))
    (if (and (< i len)
             (let ((c (bytes-ref buf i)))
               (or (= c 32) (= c 9) (= c 10) (= c 13) (= c 0))))
        (loop (+ i 1))
        i)))

;; walk one ObjStm's pair table and bodies, rebuilding each contained
;; object as standard "num 0 obj ... endobj" text the salvage
;; assembler can consume; undecodable objects are dropped silently
(define (extract-objstm obj)
  (define m-n (regexp-match #px#"/N\\s+([0-9]+)" obj))
  (define m-f (regexp-match #px#"/First\\s+([0-9]+)" obj))
  (if (and m-n m-f)
      (let* ((count (string->number (bytes->string/utf-8 (cadr m-n))))
             (first-off (string->number (bytes->string/utf-8 (cadr m-f)))))
        (if (and count first-off)
            (let ((data (objstm-stream-data obj)))
              (if data
                  (let ((body (inflate-zlib data)))
                    (if body
                        (objstm-decode body first-off count)
                        null))
                  null))
            null))
      null))

(define (objstm-decode body first-off count)
  (define pair-nums
    (filter-map
     (lambda (s) (string->number (bytes->string/utf-8 s)))
     (regexp-match* #px#"[0-9]+" (subbytes body 0 first-off))))
  ;; pairs alternate objnum gen; keep the objnums (at most `count`)
  (define nums
    (let loop ((xs pair-nums) (n 0) (acc null))
      (cond ((or (null? xs) (null? (cdr xs)) (>= n count))
             (reverse acc))
            (else (loop (cddr xs) (add1 n) (cons (car xs) acc))))))
  (let loop ((o (objstm-skip-ws body first-off))
             (todo nums)
             (acc null))
    (if (null? todo)
        (reverse acc)
        (if (>= o (bytes-length body))
            (reverse acc)
            (let-values (((nx) (objstm-scan-value body o)))
              (loop (objstm-skip-ws body nx)
                    (cdr todo)
                    (cons (cons (car todo)
                                (bytes-append
                                 (string->bytes/utf-8
                                  (format "~a 0 obj\n" (car todo)))
                                 (subbytes body o nx)
                                 #"\nendobj\n"))
                          acc)))))))

;; object numbers named by a /Kids[ ... ] array ("n 0 R" refs, deduped)
(define (kids-references obj)
  (define m (regexp-match #px#"/Kids\\s*\\[([^\\]]*)\\]" obj))
  (and m
       (remove-duplicates
        (for/list ((r (in-list (regexp-match* #px#"[0-9]+\\s+0\\s+R"
                                              (cadr m)))))
          (string->number
           (bytes->string/utf-8
            (car (regexp-match #px#"[0-9]+" r))))))))

;; compact number list for bounded diagnostics: first 8, then a count
;; tail — a truncated 1000-page tree must not flood the error channel
(define (number-run xs)
  (if (<= (length xs) 8)
      (string-join (map number->string xs) ", ")
      (string-append
       (string-join (map number->string (take xs 8)) ", ")
       " ... +" (number->string (- (length xs) 8)))))

;; walk a salvaged pages tree breadth-first from its /Type/Pages roots:
;; page-like kids become leaves, further /Pages nodes are followed, and
;; every referenced number with no usable captured object is catalogued
;; as missing (absent from the body) or damaged (present but carrying
;; no page marker — its /Type/Pages-shaped bytes did not survive).
;; Bounded rounds against self-referencing hostile trees.
(define (resolve-tree-leaves objs roots)
  (let walk ((frontier (remove-duplicates roots)) (round 0)
             (leaves (make-hash)) (missing (make-hash))
             (damaged (make-hash)))
    (if (or (null? frontier) (> round 8))
        (values (sort (hash-keys leaves) <)
                (sort (hash-keys missing) <)
                (sort (hash-keys damaged) <))
        (let ((kids null))
          (for ((k (in-list frontier)))
            (define o (hash-ref objs k #f))
            (cond
              ((not o) (hash-set! missing k #t))
              ((regexp-match? re-pages o)
               (set! kids (append kids (kids-references o))))
              ((or (regexp-match? re-page o)
                   (regexp-match? #px#"/Contents\\b" o)
                   (regexp-match? #px#"/Parent\\b" o))
               (hash-set! leaves k #t))
              (else (hash-set! damaged k #t))))
          (walk (remove-duplicates kids) (add1 round)
                leaves missing damaged)))))

;; insert /MediaBox into a page object's top-level dict (before the
;; last >> of the dict segment) when it relies on inheritance
(define (inject-mediabox obj box-bytes)
  (if (regexp-match? #px#"/MediaBox" obj)
      obj
      (let ((stream-at (bytes-find obj #"stream"))
            (hit (for/fold ((hit #f))
                           ((i (in-range 0 (- (bytes-length obj) 1))))
                   (if (and (= (bytes-ref obj i) 62)
                            (= (bytes-ref obj (add1 i)) 62))
                       i
                       hit))))
        (if hit
            (bytes-append (subbytes obj 0 hit)
                          #" /MediaBox[" box-bytes #"]"
                          (subbytes obj hit))
            obj))))

;; ---------- surviving xref-stream accounting (issue #62) ----------

;; /Index subsection list: (start . count) pairs
(define (xrefstm-sections idx)
  (let loop ((xs idx) (acc '()))
    (if (or (null? xs) (null? (cdr xs)))
        (reverse acc)
        (loop (cddr xs) (cons (cons (car xs) (cadr xs)) acc)))))

;; decode the records of one surviving /Type/XRef stream object: the
;; original document's authoritative inventory as a list of
;; (num type field2) — field2 is the byte offset for type 1 and the
;; owning object-stream number for type 2. #f when the dict or the
;; compressed payload cannot be decoded. A zero-width /W type column
;; defaults every record to type 1 per the spec.
(define (xrefstm-records obj)
  (define wm (regexp-match #px"/W\\s*\\[\\s*([0-9]+)\\s+([0-9]+)\\s+([0-9]+)\\s*\\]" obj))
  (define data (and wm (objstm-stream-data obj)))
  (define dec (and data (inflate-zlib data)))
  (and wm dec
       (let* ((w1 (string->number (bytes->string/utf-8 (cadr wm))))
              (w2 (string->number (bytes->string/utf-8 (caddr wm))))
              (w3 (string->number (bytes->string/utf-8 (cadddr wm))))
              (stride (+ w1 w2 w3))
              (size-m (regexp-match #px"/Size\\s+([0-9]{1,10})" obj))
              (size (and size-m
                         (string->number
                          (bytes->string/utf-8 (cadr size-m)))))
              (idx-m (regexp-match #px"/Index\\s*\\[([^\\]]*)\\]" obj))
              (idx (if idx-m
                       (map (lambda (b)
                              (string->number (bytes->string/utf-8 b)))
                            (regexp-match* #px"[0-9]+" (cadr idx-m)))
                       (and size (list 0 size)))))
         (and idx (even? (length idx)) (> stride 0)
              (<= (* (for/sum ((sec (in-list (xrefstm-sections idx))))
                       (cdr sec))
                    stride)
                  (bytes-length dec))
              (let section-loop ((sections (xrefstm-sections idx))
                                 (o 0)
                                 (acc '()))
                (if (null? sections)
                    (reverse acc)
                    (let record-loop ((k 0) (o o) (acc acc))
                      (if (= k (cdar sections))
                          (section-loop (cdr sections) o acc)
                          (record-loop
                           (add1 k) (+ o stride)
                           (cons (list (+ (caar sections) k)
                                       (if (zero? w1) 1 (bytes-ref dec o))
                                       (for/fold ((v 0)) ((i (in-range w2)))
                                         (+ (* v 256)
                                            (bytes-ref dec (+ o w1 i)))))
                                 acc))))))))))

;; field-report accounting for the salvage rebuild: which objects the
;; wrapper's destroyed head zone provably took (type-1 records whose
;; offset sits below body-start and whose number no surviving object
;; supplies), read from the newest surviving xref stream (incremental
;; updates append, so the last in file order is authoritative)
(define (xrefstm-head-lost xref-objs objs body-start)
  (define inv (and (pair? xref-objs)
                   (xrefstm-records (car xref-objs))))
  (values (and inv #t)
          (if inv
              (sort (remove-duplicates
                     (for/list ((r (in-list inv))
                                #:when (and (= (cadr r) 1)
                                            (< (caddr r) body-start)
                                            (not (hash-has-key? objs (car r)))))
                       (car r)))
                    <)
              '())))

;; references that no salvaged or rebuilt object resolves — the
;; blank-page signal. Computed from dict-side bytes only (stream
;; payloads are compressed binary whose chance matches are noise);
;; the xref streams are never emitted, so their /Root cannot
;; false-positive.
(define (dangling-refs nums objs rebuilt-nums)
  (define all-refs
    (for/fold ((acc '()))
              ((n (in-list nums)))
      (define obj (hash-ref objs n))
      (define sm (bytes-find obj #"stream"))
      (define dict-side (if sm (subbytes obj 0 sm) obj))
      (append
       acc
       (for/list ((m (in-list (regexp-match*
                              #px"(?<![0-9])([0-9]{1,6})[ ]+0[ ]R"
                              dict-side #:match-select cadr))))
         (string->number (bytes->string/utf-8 m))))))
  (sort (remove-duplicates
         (filter (lambda (r)
                   (not (or (hash-has-key? objs r)
                            (member r rebuilt-nums))))
                 all-refs))
        <))

;; rebuild a fresh document skeleton (new catalog + flat pages tree +
;; new classic xref + trailer) around the salvaged objects. Page
;; objects keep their original numbers; the catalog and pages tree get
;; numbers above every salvaged one. /MediaBox is inherited from a
;; salvaged /Type/Pages node when the leaves rely on it (A4 otherwise).
(define (decrypt-pdf-salvage s body-start)
  (define-values (objs objstms objstm-objs xref-objs)
    (salvage-objects s body-start))
  ;; unfold compressed object streams: the page tree of PDF 1.5+
  ;; documents lives there; independent objects win on number clashes
  (define objstm-unfolded
    (for/list ((oe (in-list objstm-objs))) (extract-objstm oe)))
  (define objstm-extracted
    (for/sum ((l (in-list objstm-unfolded))) (length l)))
  (for ((l (in-list objstm-unfolded)))
    (for ((p (in-list l)))
      (unless (hash-has-key? objs (car p))
        (hash-set! objs (car p) (cdr p)))))
  (define nums (sort (hash-keys objs) <))
  (unless (pair? nums)
    (error 'decrypt-pdf "no intact objects survive decryption"))
  ;; direct leaf sniff first; when it finds nothing, follow the
  ;; salvaged /Type/Pages tree — /Kids names the leaves explicitly, so
  ;; leaves whose /Type bytes sat in the overwritten head zone (or
  ;; whose spans a binary-noise match swallowed) still resolve, and
  ;; kids absent from the body are hard evidence of truncation
  (define pages-src
    (let ((direct (for/list ((n (in-list nums))
                             #:when (regexp-match? re-page (hash-ref objs n))
                             #:unless (regexp-match? re-pages (hash-ref objs n)))
                    n)))
      (if (pair? direct)
          direct
          (let-values (((leaves missing damaged)
                        (resolve-tree-leaves
                         objs
                         (append*
                          (for/list ((n (in-list nums))
                                     #:when (regexp-match? re-pages
                                                           (hash-ref objs n)))
                            (or (kids-references (hash-ref objs n)) null))))))
            (cond
              ;; tree resolved completely: adopt its leaf list
              ((and (pair? leaves) (null? missing) (null? damaged)) leaves)
              ((pair? missing)
               (error 'decrypt-pdf
                      "salvaged ~a object(s) but the page tree references ~a absent one(s): ~a - body truncated or pad covers only part of this file (~a compressed object stream(s), ~a object(s) unfolded)"
                      (hash-count objs) (length missing)
                      (number-run missing) objstms objstm-extracted))
              (else
               (error 'decrypt-pdf
                      "no page objects and no usable page tree among ~a salvaged object(s) (~a damaged page-tree entr(ies)) (~a compressed object stream(s), ~a object(s) unfolded)"
                      (hash-count objs) (length damaged)
                      objstms objstm-extracted)))))))
  (define maxnum (apply max nums))
  (define cat-num (add1 maxnum))
  (define pages-num (+ maxnum 2))
  (define box
    (or (for/first ((n (in-list nums))
                    #:when (regexp-match? re-pages (hash-ref objs n))
                    #:when (regexp-match? #px#"/MediaBox\\s*\\[[^\\]]*\\]"
                                          (hash-ref objs n)))
          (cadr (regexp-match #px#"/MediaBox\\s*(\\[[^\\]]*\\])"
                              (hash-ref objs n))))
        #"0 0 595 842"))
  (for ((n (in-list pages-src)))
    (hash-set! objs n (inject-mediabox (hash-ref objs n) box)))
  (define kids
    (string-join (for/list ((n (in-list pages-src))) (format "~a 0 R" n)) " "))
  ;; issue #62: losses proven by the surviving xref stream (objects
  ;; the destroyed head zone took) and references no rebuilt object
  ;; resolves — the silent-blank-page failure mode
  (define-values (xrefstm-used head-lost)
    (xrefstm-head-lost xref-objs objs body-start))
  (define dangling
    (dangling-refs nums objs (list cat-num pages-num)))
  (define parts null)
  (define offsets (make-hash))
  (define pos 0)
  (define (emit num b)
    (when num (hash-set! offsets num pos))
    (set! parts (cons b parts))
    (set! pos (+ pos (bytes-length b))))
  (emit #f #"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
  (emit cat-num
        (string->bytes/utf-8
         (format "~a 0 obj\n<< /Type /Catalog /Pages ~a 0 R >>\nendobj\n"
                 cat-num pages-num)))
  (emit pages-num
        (string->bytes/utf-8
         (format "~a 0 obj\n<< /Type /Pages /Kids[~a] /Count ~a >>\nendobj\n"
                 pages-num kids (length pages-src))))
  (for ((n (in-list nums)))
    (emit n (hash-ref objs n)))
  ;; classic xref — a CONTIGUOUS table 0..max object number: gaps get
  ;; free entries, or high-numbered objects (Root!) fall outside the
  ;; table and strict readers (qpdf) cannot resolve them
  (define all-num-records
    (sort (hash->list offsets) < #:key car))
  (define max-recorded
    (foldl max cat-num (map car all-num-records)))
  (define table-size (add1 max-recorded))
  (define xref-at pos)
  (emit #f
        (string->bytes/utf-8
         (string-append
          "xref\r\n0 " (number->string table-size) "\r\n"
          "0000000000 65535 f\r\n"
          (string-join
           (for/list ((k (in-range 1 table-size)))
             (define p (hash-ref offsets k #f))
             (if p
                 ;; record offset = the object's assembled position, not
                 ;; its number — the number-as-offset bug made every
                 ;; strict reader reject the rebuilt table
                 (string-append (zero-pad10 p) " 00000 n\r\n")
                 "0000000000 65535 f\r\n"))
           "")
          "trailer\n<< /Size " (number->string table-size)
          " /Root " (number->string cat-num) " 0 R >>\nstartxref\n"
          (number->string xref-at) "\n%%EOF\n")))
  (define assembled (apply bytes-append (reverse parts)))
  ;; spot-check: every record's offset lands on its own object header
  (define checked (length all-num-records))
  (define bad
    (for/sum ((p (in-list all-num-records)))
      (define o (cdr p))
      (define expect (string->bytes/utf-8
                      (format "~a 0 obj" (car p))))
      (if (bytes=? (subbytes assembled o (+ o (bytes-length expect)))
                   expect)
          0 1)))
  (hash 'bytes assembled
        'xrefChecked checked
        'xrefBad bad
        'headRebuilt #t
        'coverObject #f
        'pages (length pages-src)
        'xrefstmUsed xrefstm-used
        'headLost head-lost
        'danglingRefs dangling))

;; ---------- pad from a known-plaintext twin ----------

;; Twin protocol (FIELD_PROTOCOL step 2): the operator saves one file via a
;; whitelisted app (plaintext view) and copies the same file via a non-
;; whitelisted tool (wrapped ciphertext view). Voting per column over the
;; aligned pair recovers the policy pad; a few KB of twin covers every
;; column many times over.
(define (twin-vote plain cipher [base-pad (hash)])
  (unless (bytes? plain) (set! plain (string->bytes/utf-8 plain)))
  (unless (bytes? cipher) (set! cipher (string->bytes/utf-8 cipher)))
  (define n (min (bytes-length plain) (bytes-length cipher)))
  (define votes (make-hash))
  (for ([o (in-range n)])
    (define col (modulo o 512))
    (define h (hash-ref! votes col make-hash))
    (hash-set! h (bitwise-xor (bytes-ref cipher o) (bytes-ref plain o))
               (add1 (hash-ref h
                              (bitwise-xor (bytes-ref cipher o)
                                           (bytes-ref plain o))
                              0))))
  (define pad
    (make-hash (for/list ([c (in-range 512)])
                 (cons c (hash-ref base-pad c #f)))))
  (for ([(col vh) (in-hash votes)]
        #:when (>= (hash-count vh) 1))
    (define total (for/sum ([(_ c) (in-hash vh)]) c))
    (define best (argmax cdr (hash->list vh)))
    ;; unanimous-ish majority across all votes for this column
    (when (>= (cdr best) (max 3 (inexact->exact (floor (* 0.95 total)))))
      (hash-set! pad col (car best))))
  (define covered
    (for/sum ([c (in-range 512)] #:when (hash-ref pad c #f)) 1))
  (hash 'pad pad 'covered covered 'missing
        (for/list ([c (in-range 512)] #:unless (hash-ref pad c #f)) c)))

;; ---------- pad from a twin pair (shared by CLI and GUI host) ----------

;; Recovers the policy pad from an aligned plaintext/ciphertext twin pair
;; (FIELD_PROTOCOL step 2) and writes the pad JSON to out-path. The pad
;; is operator key material: it only ever reaches the operator-supplied
;; file, never a return value, so callers report coverage counters only.
;; Optional base-pad-path seeds already-known columns.
(define (write-twin-pad plain-path cipher-path out-path [base-pad-path #f])
  (define base (if base-pad-path (load-pad base-pad-path) (hash)))
  (define r (twin-vote (file->bytes plain-path)
                       (file->bytes cipher-path)
                       base))
  (define pad (hash-ref r 'pad))
  (define missing (hash-ref r 'missing))
  (with-output-to-file out-path
    (lambda ()
      (write-json
       (hash 'schemaVersion 1
             'kind "policy-pad"
             'pad (for/list ([c (in-range 512)])
                    (or (hash-ref pad c #f)
                        (json-null)))))
      (newline))
    #:exists 'replace)
  (hash 'covered (hash-ref r 'covered)
        'missing missing))

;; ---------- canonical decrypt entry (shared by CLI and GUI host) ----------

;; Decrypts an E-SafeNet-wrapped file to out-path: OOXML first (its CD is
;; findable), falling back to the PDF path. The returned report carries
;; per-entry CRC verdicts and counters only — never file contents. The
;; pad path is always explicit: --pad on the CLI, the key file
(define (decrypt-file in-path out-path pad-path)
  (unless pad-path
    (raise-arguments-error 'decrypt-file
                           "no policy pad available"
                           "resolution"
                           "CLI: pass --pad; GUI: choose the key file"))
  (define pad (load-pad pad-path))
  (define ct (file->bytes in-path))
  (parse-wrapper ct)
  (define result
    (with-handlers ([exn:fail?
                     (lambda (_)
                       (define r (decrypt-pdf ct pad))
                       (hash 'kind "pdf"
                             'headRebuilt (hash-ref r 'headRebuilt)
                             'pages (hash-ref r 'pages)
                             'coverObject (hash-ref r 'coverObject)
                             'xrefChecked (hash-ref r 'xrefChecked)
                             'xrefBad (hash-ref r 'xrefBad)
                             'xrefstmUsed (hash-ref r 'xrefstmUsed #f)
                             'headLost (hash-ref r 'headLost '())
                             'danglingRefs (hash-ref r 'danglingRefs '())
                             'bytes (hash-ref r 'bytes)))])
      (define r (decrypt-zip ct pad))
      (hash 'kind (hash-ref r 'kind)
            'entries (hash-ref r 'entries)
            'verified (hash-ref r 'verified)
            'total (hash-ref r 'total)
            'lostEntries (hash-ref r 'lostEntries)
            'recoveredEntries (hash-ref r 'recoveredEntries)
            'decryptedInner (hash-ref r 'decryptedInner)
            'bytes (hash-ref r 'bytes))))
  (with-output-to-file out-path
    (lambda () (write-bytes (hash-ref result 'bytes)))
    #:exists 'replace)
  (for/hash ([k (in-list (hash-keys result))] #:unless (equal? k 'bytes))
    (values k (hash-ref result k))))

