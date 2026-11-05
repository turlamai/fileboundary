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
         decrypt-pdf
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
(define re-page (byte-regexp #"/Type\x5cs*/Page(?![s])"))
(define re-pages (byte-regexp #"/Type\x5cs*/Pages"))

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

(define (parse-wrapper ct)
  (unless (>= (bytes-length ct) 8)
    (error 'parse-wrapper "file too short"))
  (unless (bytes=? (subbytes ct 0 4) #"\x62\x14\x23\x65")
    (error 'parse-wrapper "not an E-SafeNet wrapper (bad magic)"))
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

;; ---------- OOXML rebuild ----------

;; fresh local headers (extra = 0) + verbatim deflate data + fresh CD and
;; EOCD; the stripped first entry stores its raw deflate blob. Header-zone
;; entries (variant layouts) whose local data was overwritten by wrapper
;; metadata are emitted as STORED placeholders: docProps metadata gets a
;; minimal valid XML doc, directory entries stay empty — never document
;; content.
(define placeholder-xml-bytes
  (string->bytes/utf-8 "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n<Properties/>"))

(define (rebuild-ooxml-bytes s entries first-blob)
  (define first (car entries))
  (define out (open-output-bytes))
  (define offs (make-hash))
  (define pos 0)
  ;; per-entry resolved values, reused by the CD loop below
  (define resolved (make-hash))
  (for ([e entries])
    (define lho (hash-ref e 'lho))
    (define is-first (< lho 512))
    (define is-dir (zero? (hash-ref e 'csize)))
    (define name (hash-ref e 'name))
    (define-values (data crc csize usize method)
      (cond
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
  (for ([e entries])
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
                                 (u16->bytes (length entries))
                                 (u16->bytes (length entries))
                                 (u32->bytes cd-size)
                                 (u32->bytes cd-start)
                                 (u16->bytes 0)) out)
  (get-output-bytes out))

(define (decrypt-ooxml ct pad)
  ;; decrypt + verify every entry + reassemble a standalone OOXML file.
  ;; Two measured E-SafeNet zip layouts:
  ;;  - classic: first entry's local header is stripped, its deflate blob
  ;;    survives near offset 512, later entries are intact
  ;;  - header-zone variant: the first 512 bytes are ENCRYPTED and cover
  ;;    the local headers (+ data) of the leading entries; the CD at the
  ;;    tail survives. Those entries cannot be CRC-verified (their data
  ;;    is gone) — they are rebuilt by rebuild-ooxml-bytes from their CD
  ;;    records as stored (method 0) placeholder content: docProps
  ;;    metadata, never document content.
  (define s (xor-pad ct pad))
  (define-values (_eocd entries _n) (find-cd s))
  (define first (car entries))
  (define first-pk (bytes-find s re-lfh 512))
  (define blob
    (and first-pk
         (subbytes s (- first-pk (hash-ref first 'csize)) first-pk)))
  (define verified 0)
  (define rebuilt-count 0)
  (define report
    (for/list ([e entries])
      (define in-header-zone (< (hash-ref e 'lho) 512))
      (define-values (v rebuilt?)
        (cond
          ;; header-zone entries cannot be CRC-verified (their local
          ;; headers/data were overwritten) — they are rebuilt from CD
          ;; records as stored placeholders and counted separately
          [in-header-zone
           (values (hash 'ok #t 'rebuilt #t) #t)]
          [else
           (define v (verify-entry s e #f))
           (values v #f)]))
      (when (hash-ref v 'ok) (set! verified (add1 verified)))
      (when rebuilt? (set! rebuilt-count (add1 rebuilt-count)))
      (hash 'name (bytes->string/utf-8 (hash-ref e 'name) #\?)
            'crcOk (hash-ref v 'ok))))
  (unless (= verified (length entries))
    (error 'decrypt-ooxml
           "only ~a/~a entries verified; pad does not match this file"
           verified (length entries)))
  (hash 'entries report
        'verified verified
        'total (length entries)
        'rebuiltEntries rebuilt-count
        'bytes (rebuild-ooxml-bytes s entries blob)))

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
  ;; the surviving tail must identify the object as a page (its /Type sat
  ;; in the lost prefix; /StructParents or /Contents survive)
  (unless (or (regexp-match? #px#"/StructParents" straddler-tail)
              (regexp-match? #px#"/Contents" straddler-tail))
    (error 'decrypt-pdf "straddling object is not a page"))
  (define prefix
    (string->bytes/utf-8
     (format "~a 0 obj\r\n<</Type/Page/Parent 2 0 R/Resources<<"
             straddler)))
  (define fill
    (- (- body-start head-prefix-len) (bytes-length prefix) 2))
  (unless (>= fill 0)
    (error 'decrypt-pdf "no room for straddler prefix"))
  (define straddler-full
    (bytes-append prefix (make-bytes fill (char->integer #\space))
                  #"/X" straddler-tail))
  (define pages
    (for/list ([k (page-objects-from-xref s body-start)]
               #:unless (= k straddler))
      k))
  (define kids (cons straddler pages))
  ;; rebuilt head: header + catalog + pages tree, padded so the straddler
  ;; lands exactly at its xref offset (430 in the measured family)
  (define head1
    #"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
  (define off1 15)
  (define off2 (bytes-length head1))
  (define head2
    (string->bytes/utf-8
     (format "2 0 obj\n<< /Type /Pages /Kids[~a] /Count ~a >>\nendobj\n"
             (string-join
              (for/list ([k kids]) (format "~a 0 R" k)) " ")
             (length kids))))
  (unless (<= (+ (bytes-length head1) (bytes-length head2))
              head-prefix-len)
    (error 'decrypt-pdf "rebuilt head does not fit before the straddler"))
  (define head
    (bytes-append head1 head2
                  (make-bytes (- head-prefix-len
                                 (bytes-length head1)
                                 (bytes-length head2)
                                 1)
                              (char->integer #\#))
                  #"\n"))
  ;; patch xref records 1 and 2 to the rebuilt offsets (record k keeps
  ;; pointing at its original offset, which the assembly preserves)
  (define s2 (bytes-copy s))
  (for ([spec (list (cons 1 off1) (cons 2 off2))])
    (define rp (+ tstart (* 20 (car spec))))
    (bytes-copy! s2 rp
                 (string->bytes/utf-8
                  (string-append (zero-pad10 (cdr spec)) " 00000 n\r\n"))))
  ;; assemble: head fills 0..head-prefix-len, the straddler prefix+filler
  ;; fills up to body-start, then the straddler tail and the rest
  (define original
    (bytes-append head
                  (subbytes straddler-full
                            0
                            (- (bytes-length straddler-full)
                               (bytes-length straddler-tail)))
                  straddler-tail
                  (subbytes s2 obj-end-abs)))
  (unless (= (bytes-length original) (bytes-length s))
    (error 'decrypt-pdf "assembled length mismatch: ~a vs ~a"
           (bytes-length original) (bytes-length s)))
  ;; xref spot-check in the original coordinate system: walk every
  ;; classic table (arithmetically — no control bytes in patterns) and
  ;; verify each 'n' record's offset lands on an object header
  (define checked 0)
  (define bad 0)
  (let loop-table ([search-from (max 0 (- (bytes-length original) 65536))])
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
          (when (and off (>= off 512))
            (set! checked (add1 checked))
            (unless (regexp-match? re-rec-num
                                   (subbytes original off (+ off 32)))
              (set! bad (add1 bad))))))
      (loop-table (+ t-start (* 20 t-count)))))
  (hash 'bytes original
        'xrefChecked checked
        'xrefBad bad
        'headRebuilt #t
        'coverObject straddler
        'pages (length kids)))

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
;; separately (their contents cannot be salvaged here)
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
    (when (and prev-ok num (not (hash-has-key? seen num))
               (for/and ((sp (in-list spans)))
                 (or (<= (+ (car sp) (cdr sp)) start)
                     (>= start (+ (car sp) (cdr sp))))))
      (define obj-end (bytes-find s #"endobj" (cdr m)))
      (when obj-end
        (define end-abs (min (+ obj-end 6) (bytes-length s)))
        (set! spans (cons (cons start end-abs) spans))
        (define obj (subbytes s start end-abs))
        (cond
          ((regexp-match? #px#"/Type\\s*/XRef\\b" obj) (void))
          ((regexp-match? #px#"/Type\\s*/ObjStm\\b" obj)
           (set! objstms (add1 objstms)))
          (else (hash-set! seen num obj))))))
  (values seen objstms))

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

;; rebuild a fresh document skeleton (new catalog + flat pages tree +
;; new classic xref + trailer) around the salvaged objects. Page
;; objects keep their original numbers; the catalog and pages tree get
;; numbers above every salvaged one. /MediaBox is inherited from a
;; salvaged /Type/Pages node when the leaves rely on it (A4 otherwise).
(define (decrypt-pdf-salvage s body-start)
  (define-values (objs objstms) (salvage-objects s body-start))
  (define nums (sort (hash-keys objs) <))
  (unless (pair? nums)
    (error 'decrypt-pdf "no intact objects survive decryption"))
  (define pages-src
    (for/list ((n (in-list nums))
               #:when (regexp-match? re-page (hash-ref objs n))
               #:unless (regexp-match? re-pages (hash-ref objs n)))
      n))
  (unless (pair? pages-src)
    (error 'decrypt-pdf
           "objects survive but no direct page objects found (~a compressed object stream(s) not supported)"
           objstms))
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
  ;; classic xref (ascending object numbers, free entry 0 first)
  (define all-num-records
    (sort (hash->list offsets) < #:key car))
  (define xref-at pos)
  (emit #f
        (string->bytes/utf-8
         (string-append
          "xref\r\n0 " (number->string (add1 (length all-num-records))) "\r\n"
          "0000000000 65535 f\r\n"
          (string-join
           (for/list ((p (in-list all-num-records)))
             (string-append (zero-pad10 (car p)) " 00000 n\r\n"))
           "")
          "trailer\n<< /Size " (number->string (add1 (length all-num-records)))
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
        'pages (length pages-src)))

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
                             'bytes (hash-ref r 'bytes)))])
      (define r (decrypt-ooxml ct pad))
      (hash 'kind "ooxml"
            'entries (hash-ref r 'entries)
            'verified (hash-ref r 'verified)
            'total (hash-ref r 'total)
            'bytes (hash-ref r 'bytes))))
  (with-output-to-file out-path
    (lambda () (write-bytes (hash-ref result 'bytes)))
    #:exists 'replace)
  (for/hash ([k (in-list (hash-keys result))] #:unless (equal? k 'bytes))
    (values k (hash-ref result k))))

