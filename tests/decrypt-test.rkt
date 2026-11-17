#lang racket/base

;; Decryption engine tests (T0 productization): CRC32 vectors, twin-vote
;; pad recovery, and end-to-end decryption of the pinned real fixtures
;; (research/t0/fixtures, ADR-0007). Read-only against fixtures; outputs
;; go to temporary directories only.

(require rackunit
         json
         racket/file
         racket/port
         racket/runtime-path
         racket/string
         file/unzip
         "../src/engine/decrypt.rkt")

(define-runtime-path fixtures-dir
  "../research/t0/fixtures")
(define-runtime-path pad-path
  "../research/t0/pad_full.json")
(define-runtime-path twin-plain
  "../tests/fixtures/real-samples/plaintext-sample.docx")

;; ---------- CRC32 vectors ----------

(check-equal? (crc32-bytes #"") 0)
(check-equal? (crc32-bytes #"123456789") #xCBF43926)
(check-equal? (crc32-bytes #"The quick brown fox jumps over the lazy dog")
              #x414FA339)

;; ---------- pad ----------

(define pad (load-pad pad-path))
(check-equal? (hash-count pad) 512)

;; ---------- xlsx fixture: end-to-end OOXML decryption ----------

(define xlsx-ct
  (file->bytes (build-path fixtures-dir
                           "esafenet-wrapped-radar-motor-sheet.xlsx")))
(define xlsx (decrypt-ooxml xlsx-ct pad))
(check-equal? (hash-ref xlsx 'total) 23)
(check-equal? (hash-ref xlsx 'verified) 23)
(check-true (andmap (lambda (e) (hash-ref e 'crcOk))
                    (hash-ref xlsx 'entries)))

;; the standalone output must be a working zip again
(define out-zip (make-temporary-file "fb-dec~a.xlsx"))
(with-output-to-file out-zip
  (lambda () (write-bytes (hash-ref xlsx 'bytes))) #:exists 'replace)
(define zf-entries (make-hash))
(call-with-input-file out-zip
  (lambda (in)
    (unzip in (lambda (name is-dir? port)
                (when (equal? name #"xl/workbook.xml")
                  (hash-set! zf-entries
                             'workbook (port->bytes port)))))))
(check-true (hash-has-key? zf-entries 'workbook))
(check-true (regexp-match? #rx#"workbook" (hash-ref zf-entries 'workbook)))

;; strict central-directory conformance: tolerant scanners accept a broken
;; CD, but strict readers (Explorer, some Office parsers, zipfile) trust
;; the EOCD cd_size/cd_ofs fields and the 46-byte record stride — the
;; rebuilt archive must conform, not merely scan
(define (check-strict-zip bs)
  (define n (bytes-length bs))
  (define eocd (for/first ([i (in-range (- n 22) -1 -1)]
                           #:when (bytes=? (subbytes bs i (+ i 4))
                                           #"PK\x05\x06"))
                 i))
  (check-true (number? eocd))
  (define (u16 o) (+ (bytes-ref bs o) (* 256 (bytes-ref bs (+ o 1)))))
  (define (u32 o)
    (+ (bytes-ref bs o) (* 256 (bytes-ref bs (+ o 1)))
       (* 65536 (bytes-ref bs (+ o 2)))
       (* 16777216 (bytes-ref bs (+ o 3)))))
  (define n-entries (u16 (+ eocd 10)))
  (define cd-size (u32 (+ eocd 12)))
  (define cd-ofs (u32 (+ eocd 16)))
  (check-equal? n-entries 23)
  (check-true (> cd-size 0))
  (check-true (bytes=? (subbytes bs cd-ofs (+ cd-ofs 4)) #"PK\x01\x02"))
  ;; walk the CD: records must fill cd_size exactly and every local
  ;; header offset must land on a PK\x03\x04 with the matching name
  (let loop ([o cd-ofs] [seen 0])
    (if (= seen n-entries)
        (check-equal? o (+ cd-ofs cd-size))
        (let* ([name-len (u16 (+ o 28))]
               [lho (u32 (+ o 42))]
               [name (subbytes bs (+ o 46) (+ o 46 name-len))])
          (check-true (bytes=? (subbytes bs o (+ o 4)) #"PK\x01\x02"))
          (check-true (bytes=? (subbytes bs lho (+ lho 4)) #"PK\x03\x04"))
          (check-true (bytes=? (subbytes bs (+ lho 30) (+ lho 30 name-len))
                               name))
          (loop (+ o 46 name-len) (add1 seen))))))
(check-strict-zip (hash-ref xlsx 'bytes))

;; ---------- docx twin fixture ----------

(define docx-ct
  (file->bytes (build-path fixtures-dir ".." ".." ".."
                           "tests" "fixtures" "real-samples"
                           "encrypted-sample.docx")))
(define docx (decrypt-ooxml docx-ct pad))
(check-equal? (hash-ref docx 'total) 12)
(check-equal? (hash-ref docx 'verified) 12)

;; content fingerprint: '123' and 'abc' runs in word/document.xml
(define doc-entry
  (for/first ([e (hash-ref docx 'entries)]
              #:when (equal? (hash-ref e 'name) "word/document.xml"))
    e))
(check-true (hash-ref doc-entry 'crcOk))

;; ---------- PDF fixture: end-to-end with semantic head rebuild ----------

(define pdf-ct
  (file->bytes (build-path fixtures-dir
                           "esafenet-wrapped-courseware.pdf")))
(define pdf (decrypt-pdf pdf-ct pad))
(check-equal? (hash-ref pdf 'xrefBad) 0)
(check-true (>= (hash-ref pdf 'xrefChecked) 100))
(check-true (>= (hash-ref pdf 'pages) 20))
(check-equal? (hash-ref pdf 'coverObject) 3)
(define pdf-out (hash-ref pdf 'bytes))
(check-equal? (bytes-length pdf-out) (bytes-length pdf-ct))
;; tail must carry a valid PDF trailer
(check-true (regexp-match? #rx#"startxref" (subbytes pdf-out (- (bytes-length pdf-out) 200))))
(check-true (regexp-match? #rx#"%%EOF" (subbytes pdf-out (- (bytes-length pdf-out) 16))))
;; head must be a PDF header + catalog
(check-true (regexp-match? #rx#"^%PDF-1\\." (subbytes pdf-out 0 16)))

;; ---------- twin-vote: pad recovery from an aligned pair ----------

;; synthesize a ciphertext twin of the committed plaintext twin with the
;; known policy pad, then recover the pad from the pair alone
(define plain (file->bytes twin-plain))
(define synth-cipher (make-bytes (bytes-length plain)))
(for ([o (in-range (bytes-length plain))])
  (bytes-set! synth-cipher o
              (bitwise-xor (bytes-ref plain o)
                           (hash-ref pad (modulo o 512)))))
(define recovered (twin-vote plain synth-cipher))
(check-equal? (hash-ref recovered 'covered) 512)
(check-equal? (hash-ref recovered 'missing) '())
(define rpad (hash-ref recovered 'pad))
(check-equal?
 (for/sum ([c (in-range 512)]
           #:unless (= (hash-ref rpad c) (hash-ref pad c)))
   1)
 0)

;; a second twin round on top of a partial pad still converges
(define partial (for/hash ([c (in-range 512)] #:when (even? c))
                  (values c (hash-ref pad c))))
(define recovered2 (twin-vote plain synth-cipher partial))
(check-equal? (hash-ref recovered2 'covered) 512)

;; ---------- write-twin-pad: pad JSON via the shared CLI/GUI entry ----------

;; recover from files on disk (the shape the CLI and the GUI RPC use),
;; then prove the written pad decrypts the real wrapped twin
(define twin-dir (make-temporary-file "fb-twin~a/" 'directory))
(define twin-plain-path (build-path twin-dir "plain.docx"))
(copy-file twin-plain twin-plain-path)
(define twin-cipher-path (build-path twin-dir "cipher.docx"))
(define twin-plain-bytes (file->bytes twin-plain-path))
(define twin-cipher-bytes
  (let ([ct (make-bytes (bytes-length twin-plain-bytes))])
    (for ([o (in-range (bytes-length twin-plain-bytes))])
      (bytes-set! ct o (bitwise-xor (bytes-ref twin-plain-bytes o)
                                    (hash-ref pad (modulo o 512)))))
    ct))
(call-with-output-file twin-cipher-path
  (lambda (out) (write-bytes twin-cipher-bytes out)))
(define twin-report (write-twin-pad twin-plain-path twin-cipher-path
                                    (build-path twin-dir "pad.json")))
(check-equal? (hash-ref twin-report 'covered) 512)
(check-equal? (hash-ref twin-report 'missing) '())

;; the written pad file is loadable and decrypts the real wrapped twin
(define repad (load-pad (build-path twin-dir "pad.json")))
(check-equal? (hash-count repad) 512)
(define docx2 (decrypt-ooxml
               (file->bytes (build-path fixtures-dir ".." ".." ".."
                                        "tests" "fixtures" "real-samples"
                                        "encrypted-sample.docx"))
               repad))
(check-equal? (hash-ref docx2 'verified) 12)
(check-equal? (hash-ref docx2 'total) 12)

;; base-pad seeding: a partial pad still converges through the file path
(define partial-pad-path (build-path twin-dir "partial-pad.json"))
(call-with-output-file partial-pad-path
  (lambda (out)
    (write-json
     (hash 'schemaVersion 1
           'kind "policy-pad"
           'pad (for/list ([c (in-range 512)])
                  (if (even? c) (hash-ref pad c) (json-null))))
     out)))
(check-equal? (hash-ref (write-twin-pad twin-plain-path twin-cipher-path
                                        (build-path twin-dir "pad2.json")
                                        partial-pad-path)
                        'covered)
              512)

;; ---------- wrapper magic variants ----------

;; Variant B (64 14 23 65) seen in the field: only the first magic
;; byte differs; the body pipeline must still decrypt the file. Prove
;; it end to end on the real fixture with the first byte flipped.
(define variant-b-ct
  (bytes-copy xlsx-ct))
(bytes-copy! variant-b-ct 0 #"\x64" 0 1)
(define variant-b (decrypt-file (path->string (build-path fixtures-dir
                                                       "esafenet-wrapped-radar-motor-sheet.xlsx"))
                                (path->string (make-temporary-file "fb-varb~a.xlsx"))
                                (path->string pad-path)))
(check-equal? (hash-ref variant-b 'kind) "ooxml")

;; parse-wrapper itself accepts both magics and reports the variant
(check-equal? (call-with-values
               (lambda () (parse-wrapper #"\x64\x14\x23\x65\x01\x02\x03\x04")) list)
              (list #x0201 #x0403))

;; ---------- salvage: spaced canonical dict forms ("/Type /Page") ------

;; Regressions for the field failure "objects survive but no direct
;; page objects found": plain byte-regexp patterns treated \s as a
;; literal "s", so the spaced canonical PDF dict form never matched
;; and every page sniff came up empty on producers that write it.

;; spaced independent leaves + spaced pages tree: the direct leaf
;; sniff must now match without falling back to the tree walk
(define spaced-body
  (xor-pad
   (string->bytes/utf-8
    (string-append
     (make-string 512 #\A)
     "\n10 0 obj\n<< /Type /Pages /Kids [1 0 R 2 0 R] /Count 2 >>\nendobj\n"
     "\n1 0 obj\n<< /Type /Page /Parent 10 0 R /Contents 20 0 R >>\nendobj\n"
     "\n2 0 obj\n<< /Type /Page /Parent 10 0 R /Contents 20 0 R >>\nendobj\n"
     "\n20 0 obj\n<< /Length 8 >>\nstream\nBT ET\nendstream\nendobj\n"))
   pad))
(define spaced-ok (decrypt-pdf spaced-body pad))
(check-equal? (hash-ref spaced-ok 'pages) 2)
(check-equal? (hash-ref spaced-ok 'xrefBad) 0)

;; the user-facing failure profile end to end: the page leaves live in
;; an ObjStm whose dict is also written in the spaced form, so the
;; pre-fix engine neither matched the tree nor unfolded the stream
(require file/gzip
         file/zip)
(define (adler32 bs)
  (define-values (a b)
    (for/fold ((a 1) (b 0))
              ((c (in-bytes bs)))
      (values (modulo (+ a c) 65521) (modulo (+ b a c) 65521))))
  (+ (* b 65521) a))
(define (zlib-deflate bs)
  (define out (open-output-bytes))
  (write-byte #x78 out)
  (write-byte #x9C out)
  (define-values (_in _out _crc) (deflate (open-input-bytes bs) out))
  (define n (adler32 bs))
  (bytes-append (get-output-bytes out)
                (bytes (bitwise-and (arithmetic-shift n -24) 255)
                       (bitwise-and (arithmetic-shift n -16) 255)
                       (bitwise-and (arithmetic-shift n -8) 255)
                       (bitwise-and n 255))))
(define objstm-payload
  (string->bytes/utf-8
   (string-append
    "1 0 2 0 "
    "<< /Type /Page /Parent 10 0 R /Contents 20 0 R >>\n"
    "<< /Type /Page /Parent 10 0 R /Contents 20 0 R >>\n")))
(define objstm-stream (zlib-deflate objstm-payload))
(define objstm-body
  (string->bytes/utf-8
   (string-append
    "\n5 0 obj\n<< /Type /ObjStm /N 2 /First 8 /Filter /FlateDecode /Length "
    (number->string (bytes-length objstm-stream))
    " >>\nstream\n")))
(define spaced-objstm-body
  (xor-pad
   (bytes-append
    (string->bytes/utf-8 (make-string 512 #\A))
    (string->bytes/utf-8
     "\n10 0 obj\n<< /Type /Pages /Kids [1 0 R 2 0 R] /Count 2 >>\nendobj\n")
    objstm-body
    objstm-stream
    #"\nendstream\nendobj\n"
    (string->bytes/utf-8
     "\n20 0 obj\n<< /Length 8 >>\nstream\nBT ET\nendstream\nendobj\n"))
   pad))
(define spaced-objstm-ok (decrypt-pdf spaced-objstm-body pad))
(check-equal? (hash-ref spaced-objstm-ok 'pages) 2)
(check-equal? (hash-ref spaced-objstm-ok 'xrefBad) 0)

;; ---------- salvage: pages-tree resolution (PDF 1.5+ no-xref bodies) --

;; synthetic body whose page LEAVES lost their /Type bytes (they sat in
;; the overwritten head zone — the field failure mode behind "no direct
;; page objects found"): the direct leaf sniff must come up empty and
;; the salvaged /Type/Pages tree must resolve the leaves via /Kids.
;; The body is fabricated with the pad itself (XOR is its own inverse).
(define (salvage-body kids-list leaf-tail)
  (define body
    (string->bytes/utf-8
     (string-append
      (make-string 512 #\A)
      "\n5 0 obj\n<< /Type /Pages /Kids[" kids-list "] /Count 2 >>\nendobj\n"
      "\n1 0 obj\n<< /Parent 5 0 R /Contents 7 0 R /Resources << >> >>\nendobj\n"
      "\n2 0 obj\n<< /Parent 5 0 R /Contents 7 0 R /Resources << >> >>\nendobj\n"
      "\n7 0 obj\n<< /Length 12 >>\nstream\nBT ET endobj\n" leaf-tail)))
  (xor-pad body pad))

;; both leaves survive: the tree recovers them even without /Type/Page
(define tree-ok (decrypt-pdf (salvage-body "1 0 R 2 0 R" "") pad))
(check-equal? (hash-ref tree-ok 'pages) 2)
(check-equal? (hash-ref tree-ok 'xrefBad) 0)

;; a leaf referenced by /Kids but absent from the body is hard
;; evidence of truncation: the error must name the missing number
(define truncated-msg
  (with-handlers ((exn:fail? (lambda (e) (exn-message e))))
    (decrypt-pdf (salvage-body "1 0 R 2 0 R 3 0 R" "") pad)
    #f))
(check-true (and truncated-msg
                 (regexp-match? #rx"references 1 absent" truncated-msg)
                 (string-contains? truncated-msg "absent one(s): 3 ")
                 (regexp-match? #rx"truncated or pad covers only part" truncated-msg)))

;; ---------- wrapped plain zip + nested entry decryption ----------

;; field sample (variant C magic 63 14 23 65, 2026-11-09): the whole
;; archive is wrapped, two leading entries live in the header zone —
;; the BOM directory survives empty and the BOM xlsx content exists
;; nowhere in the file (E-SafeNet restores it through its read-time
;; driver, so it is reported lost instead of shipped corrupt)
(define zip-fixture
  (decrypt-zip (file->bytes (build-path fixtures-dir
                                        "esafenet-wrapped-zip-archive.zip"))
               pad))
(check-equal? (hash-ref zip-fixture 'kind) "zip")
(check-equal? (hash-ref zip-fixture 'total) 8)
(check-equal? (hash-ref zip-fixture 'verified) 7)
(check-equal? (length (hash-ref zip-fixture 'lostEntries)) 1)
(check-equal? (hash-ref zip-fixture 'decryptedInner) 0)

;; the output zip reads back cleanly: 5 content files, every .pdf a
;; real PDF (the GBK entry names travel as raw bytes and are preserved)
(define zip-out (make-temporary-file "fb-zipd~a.zip"))
(with-output-to-file zip-out
  (lambda () (write-bytes (hash-ref zip-fixture 'bytes))) #:exists 'replace)
(define entry-count 0)
(define pdf-ok #f)
(call-with-input-file zip-out
  (lambda (in)
    (unzip in
           (lambda (name is-dir? port)
             (unless is-dir? (set! entry-count (add1 entry-count)))
             (when (and (not is-dir?) (regexp-match? #rx#"[.]pdf$" name))
               (set! pdf-ok
                     (equal? (read-bytes 4 port) #"%PDF")))))))
(check-equal? entry-count 5)
(check-true pdf-ok)
(delete-file zip-out)

;; ---------- synthetic nesting (variant C geometry) ----------

;; the measured wrapper geometry: a 512-byte wrapper header (variant C
;; magic + zone fields + E-SafeNet marker) replaces the file's first
;; 512 bytes; the body from 512 on is the original bytes, which xor-pad
;; recovers exactly
(define (seeded-random! _rg)
  ;; deterministic filler geometry: the tests assert structural facts
  ;; (which entries land in the header zone), not PRNG output
  (random-seed 20261109))

(define (wrap-variant-c plain)
  ;; the measured model: the WHOLE file is first XOR-encrypted with the
  ;; pad, then the wrapper header replaces the first 512 bytes — the
  ;; synthesized ciphertext is head(512) + (xor-pad plain)[512:]
  (define head (make-bytes 512))
  (bytes-copy! head 0 #"\x63\x14\x23\x65" 0 4)
  (bytes-set! head 4 21)   ; zone = 21 (le16)
  (bytes-set! head 6 235)  ; tail = 491 (le16) → zone+tail = 512
  (bytes-set! head 7 1)
  (for ([i (in-range 12 21)])
    (bytes-set! head i (char->integer (string-ref "E-SafeNet" (- i 12)))))
  (bytes-append head (subbytes (xor-pad plain pad) 512)))

;; a zip with one 2 KiB incompressible filler entry (which lands in the
;; header zone and is therefore lost) plus one named payload entry;
;; names are stored RELATIVE (file/zip archives the paths as given) and
;; zipping runs under the work directory so names stay clean
(define (make-two-entry-zip payload-name payload-bytes work-tag)
  (define d (build-path (find-system-path 'temp-dir)
                        (string-append "fb-zipnest-" work-tag)))
  (make-directory* d)
  (define filler (build-path d "dummy.bin"))
  ;; incompressible filler: constant bytes would deflate to a few dozen
  ;; bytes and pull every later local header into the header zone
  (define rnd (make-bytes 2048))
  (seeded-random! #f)
  (for ([i (in-range 2048)])
    (bytes-set! rnd i (random 256)))
  (call-with-output-file filler
    (lambda (out) (write-bytes rnd out)) #:exists 'truncate)
  (define payload (build-path d payload-name))
  (call-with-output-file payload
    (lambda (out) (write-bytes payload-bytes out)) #:exists 'truncate)
  (define z (build-path d "archive.zip"))
  (with-handlers ([exn:fail? void]) (delete-file z))
  (parameterize ([current-directory d])
    (zip z "dummy.bin" payload-name))
  (file->bytes z))

;; inner zip A: filler + payload.txt → wrapped variant C
(define inner-zip-plain
  (make-two-entry-zip "payload.txt" (string->bytes/utf-8 "nested payload 42")
                      "a"))
(define inner-zip-wrapped (wrap-variant-c inner-zip-plain))

;; inner PDF: the real decrypted courseware output, wrapped variant C
(define inner-pdf-wrapped
  (wrap-variant-c (hash-ref pdf 'bytes)))

;; outer zip B: filler + note.txt + the two wrapped inner files →
;; wrapped variant C on top
(define nest-dir (build-path (find-system-path 'temp-dir) "fb-zipnest-b"))
(make-directory* nest-dir)
(define (write-member name bytes)
  (call-with-output-file (build-path nest-dir name)
    (lambda (out) (write-bytes bytes out)) #:exists 'truncate))
(define outer-rnd (make-bytes 2048))
(seeded-random! #f)
(for ([i (in-range 2048)])
  (bytes-set! outer-rnd i (random 256)))
(write-member "dummy.bin" outer-rnd)
(write-member "note.txt" (string->bytes/utf-8 "outer note"))
(write-member "first.pdf" inner-pdf-wrapped)
(write-member "second.zip" inner-zip-wrapped)
(define outer-zip-path (build-path nest-dir "outer.zip"))
(with-handlers ([exn:fail? void]) (delete-file outer-zip-path))
(parameterize ([current-directory nest-dir])
  (zip outer-zip-path "dummy.bin" "note.txt" "first.pdf" "second.zip"))
(define outer-wrapped
  (wrap-variant-c (file->bytes outer-zip-path)))

(define nested
  (decrypt-zip outer-wrapped pad))
(check-equal? (hash-ref nested 'kind) "zip")
(check-equal? (hash-ref nested 'decryptedInner) 2)
(check-equal? (length (hash-ref nested 'lostEntries)) 1)  ; the filler

;; read the decrypted zip back: the plain note survives verbatim and the
;; two nested-wrapped members come out as their ORIGINAL plaintexts
(define nest-out (make-temporary-file "fb-zipn~a.zip"))
(with-output-to-file nest-out
  (lambda () (write-bytes (hash-ref nested 'bytes))) #:exists 'replace)
(define members (make-hash))
(call-with-input-file nest-out
  (lambda (in)
    (unzip in
           (lambda (name is-dir? port)
             (unless is-dir?
               (hash-set! members name (port->bytes port)))))))
(check-equal? (hash-ref members #"note.txt") #"outer note")
(check-equal? (hash-ref members #"first.pdf") (hash-ref pdf 'bytes))
;; the nested pass on second.zip must equal a direct decrypt of the
;; same wrapped bytes (whose own header-zone filler is lost there)
(check-equal?
 (hash-ref members #"second.zip")
 (hash-ref (decrypt-zip inner-zip-wrapped pad) 'bytes))
(delete-file nest-out)

;; depth guard: the innermost level is a plain (unwrapped) zip, so a
;; 4-deep chain still decrypts, while 6 wraps exceed the bounded limit
(define (nest-n-times bytes n)
  ;; each level is a two-entry wrapped zip: the filler soaks up the
  ;; header zone so the inner.zip entry survives past offset 512
  (for/fold ([b bytes]) ([i (in-range n)])
    (wrap-variant-c
     (make-two-entry-zip (format "l~a.zip" i) b (format "d~a" i)))))
(check-not-false
 (decrypt-zip (nest-n-times inner-zip-wrapped 4) pad))
(check-exn
 exn:fail?
 (lambda () (decrypt-zip (nest-n-times inner-zip-wrapped 6) pad)))

;; a wrapped payload that is neither a zip container nor a PDF fails
;; loudly with the entry name, instead of shipping still-wrapped bytes
(define wrapped-txt
  (wrap-variant-c
   (string->bytes/utf-8
    (string-append "plain text payload " (make-string 600 #\x)))))
(check-exn
 exn:fail?
 (lambda ()
   (decrypt-zip (wrap-variant-c
                 (make-two-entry-zip "notes.bin" wrapped-txt "t"))
                pad)))
(check-exn
 #px"notes[.]bin"
 (lambda ()
   (decrypt-zip (wrap-variant-c
                 (make-two-entry-zip "notes.bin" wrapped-txt "t2"))
                pad)))

;; ---------- header-zone boundary recovery (owner field report 2026-11-17) ------

;; The wrapper destroys exactly the file's first 512 bytes. The zone rule
;; classified by POSITION (lho < 512), not by DAMAGE: an archive member
;; the owner added to a wrapped zip landed with its local header inside
;; the zone while its DATA started past 512 - every content byte
;; survived, only the local header (name/extra lengths) was destroyed.
;; Recovery must rebuild the header from the central directory, gate on
;; the entry's own method/CRC/usize, and must never fabricate content
;; for members whose data genuinely starts inside the zone.

;; hand-built all-STORED archive so every offset is exact
(define (hz-u16 v)
  (bytes (bitwise-and v 255) (bitwise-and (arithmetic-shift v -8) 255)))
(define (hz-u32 v)
  (bytes-append (hz-u16 v) (hz-u16 (arithmetic-shift v -16))))
(define (hz-lfh name data)
  (bytes-append #"PK\x03\x04" (hz-u16 20) (hz-u16 0) (hz-u16 0)
                (hz-u16 0) (hz-u16 0)
                (hz-u32 (crc32-bytes data))
                (hz-u32 (bytes-length data))
                (hz-u32 (bytes-length data))
                (hz-u16 (bytes-length name)) (hz-u16 0) name data))
(define (hz-cd name data lho)
  (bytes-append #"PK\x01\x02" (hz-u16 20) (hz-u16 20) (hz-u16 0) (hz-u16 0)
                (hz-u16 0) (hz-u16 0)
                (hz-u32 (crc32-bytes data))
                (hz-u32 (bytes-length data)) (hz-u32 (bytes-length data))
                (hz-u16 (bytes-length name)) (hz-u16 0) (hz-u16 0)
                (hz-u16 0) (hz-u16 0) (hz-u32 0)
                (hz-u32 lho) name))
(define (hz-zip specs)
  ;; specs: list of (name-bytes data-bytes); entries stored, back-to-back
  (define-values (body ents)
    (for/fold ([acc #""] [es '()]) ([sp (in-list specs)])
      (define part (hz-lfh (car sp) (cadr sp)))
      (values (bytes-append acc part)
              (cons (list (car sp) (cadr sp) (bytes-length acc)) es))))
  (define ordered (reverse ents))
  (define cds
    (apply bytes-append
           (for/list ([e (in-list ordered)]) (hz-cd (car e) (cadr e) (caddr e)))))
  (bytes-append body cds #"PK\x05\x06" (hz-u16 0) (hz-u16 0)
                (hz-u16 (length ordered)) (hz-u16 (length ordered))
                (hz-u32 (bytes-length cds)) (hz-u32 (bytes-length body))
                (hz-u16 0)))

;; geometry: d/ (lho 0), pad.bin (lho 32, data 69..489 - fully inside the
;; destroyed zone), big.bin (lho 489, data 526..1526 - header inside the
;; zone, data past it), tail.txt (lho 1526, intact)
(define hz-big-data
  (let ([b (make-bytes 1000)])
    (for ([i (in-range 1000)])
      (bytes-set! b i (modulo (+ i 7) 256)))
    b))
(define hz-plain
  (hz-zip (list (list #"d/" #"")
                (list #"pad.bin" (make-bytes 420 65))
                (list #"big.bin" hz-big-data)
                (list #"tail.txt" (string->bytes/utf-8 "tail-bytes")))))
;; the geometry contract this fixture exists for: big.bin's local header
;; sits inside the zone while its data starts past it
(check-equal? (subbytes hz-plain 489 493) #"PK\x03\x04")
(check-equal? (subbytes hz-plain 526 530) (subbytes hz-big-data 0 4))
(define hz-report (decrypt-zip (wrap-variant-c hz-plain) pad))
(check-equal? (hash-ref hz-report 'kind) "zip")
(check-equal? (hash-ref hz-report 'total) 4)
;; pad.bin is genuinely destroyed (data 69..489 inside the zone) and must
;; stay lost; big.bin is fully recoverable and must come out intact
(check-equal? (hash-ref hz-report 'verified) 3)  ; d/ + big.bin + tail.txt
(check-equal? (hash-ref hz-report 'recoveredEntries) 1)
(check-equal? (hash-ref hz-report 'lostEntries) '("pad.bin"))
(define hz-out (make-temporary-file "fb-hz~a.zip"))
(with-output-to-file hz-out
  (lambda () (write-bytes (hash-ref hz-report 'bytes))) #:exists 'replace)
(define hz-members (make-hash))
(call-with-input-file hz-out
  (lambda (in)
    (unzip in (lambda (name is-dir? port)
                (unless is-dir?
                  (hash-set! hz-members name (port->bytes port)))))))
(check-equal? (hash-ref hz-members #"big.bin" #f) hz-big-data)
(check-equal? (hash-ref hz-members #"tail.txt" #f) #"tail-bytes")
(check-false (hash-ref hz-members #"pad.bin" #f))
(delete-file hz-out)

;; a member whose data straddles the zone boundary (start < 512 <= end)
;; is genuinely destroyed at its head: it must stay lost, never rebuilt
;; from the surviving tail. Geometry: c/ (lho 0), fill.bin (lho 32, data
;; 70..469), cross.bin (lho 469, data 508..1208 - straddles), end.txt
;; (lho 1209... measured from construction), intact
(define hz-cross-plain
  (hz-zip (list (list #"c/" #"")
                (list #"fill.bin" (make-bytes 399 66))
                (list #"cross.bin" (make-bytes 700 67))
                (list #"end.txt" (string->bytes/utf-8 "end")))))
(check-equal? (subbytes hz-cross-plain 469 473) #"PK\x03\x04")
(check-equal? (subbytes hz-cross-plain 508 512) (make-bytes 4 67))
(define hz-cross-report (decrypt-zip (wrap-variant-c hz-cross-plain) pad))
(check-equal? (hash-ref hz-cross-report 'total) 4)
(check-equal? (hash-ref hz-cross-report 'recoveredEntries) 0)
(check-equal? (hash-ref hz-cross-report 'verified) 2)  ; c/ + end.txt
(check-equal? (length (hash-ref hz-cross-report 'lostEntries)) 2)

;; a RECOVERED member that is itself an E-SafeNet-wrapped nested archive
;; must go through the same same-pass nested decryption as any other
;; member (field parity: the owner can add wrapped files to archives).
;; Geometry: c3/ (lho 0), fill2.bin (lho 33, data 71..491), nested.bin
;; (lho 491, data 531.. - header in the zone, data past it), end3.txt.
(define hz-inner-plain
  (hz-zip (list (list #"fill.txt" (make-bytes 480 68))
                (list #"keep.txt" (string->bytes/utf-8 "inner-keep")))))
(define hz-nested-report
  (decrypt-zip
   (wrap-variant-c
    (hz-zip (list (list #"c3/" #"")
                  (list #"fill2.bin" (make-bytes 420 69))
                  (list #"nested.bin" (wrap-variant-c hz-inner-plain))
                  (list #"end3.txt" (string->bytes/utf-8 "end3")))))
   pad))
(check-equal? (hash-ref hz-nested-report 'total) 4)
(check-equal? (hash-ref hz-nested-report 'verified) 3)  ; c3/ nested end3
(check-equal? (hash-ref hz-nested-report 'recoveredEntries) 1)
(check-equal? (hash-ref hz-nested-report 'decryptedInner) 1)
(check-equal? (hash-ref hz-nested-report 'lostEntries) '("fill2.bin"))
(define hz-nested-out (make-temporary-file "fb-hzn~a.zip"))
(with-output-to-file hz-nested-out
  (lambda ()
    (write-bytes (hash-ref hz-nested-report 'bytes))) #:exists 'replace)
(define hz-nested-members (make-hash))
(call-with-input-file hz-nested-out
  (lambda (in)
    (unzip in (lambda (name is-dir? port)
                (unless is-dir?
                  (hash-set! hz-nested-members name (port->bytes port)))))))
(check-equal? (hash-ref hz-nested-members #"end3.txt" #f) #"end3")
(check-false (hash-ref hz-nested-members #"fill2.bin" #f))
;; the recovered nested.bin is the inner archive decrypted in the same
;; pass: fill.txt (crossing the inner zone) lost, keep.txt intact
(define hz-inner-round
  (call-with-input-bytes (hash-ref hz-nested-members #"nested.bin")
    (lambda (in)
      (define acc (make-hash))
      (unzip in (lambda (name is-dir? port)
                  (unless is-dir?
                    (hash-set! acc name (port->bytes port)))))
      acc)))
(check-equal? (hash-ref hz-inner-round #"keep.txt" #f) #"inner-keep")
(check-false (hash-ref hz-inner-round #"fill.txt" #f))
(delete-file hz-nested-out)

;; ---------- classic-xref straddler layouts (field reports 2026-11) ----------

;; Two field layouts the classic rebuild mishandled (owner reports,
;; 2026-11): a page object cut mid-reference inside its /Resources
;; sub-dictionaries rebuilt with an unbalanced prefix, so /MediaBox and
;; /Contents landed outside the page dictionary and the FIRST page
;; rendered blank; and a pages-tree ROOT cut mid-/Kids aborted with
;; "straddling object is not a page". A third report exposed that the
;; post-rebuild xref spot-check only looked at the last 64 KiB: an xref
;; table larger than 64 KiB (4 005 entries in the field file) starts
;; outside that window and was verified not at all. The fixtures below
;; are fully synthetic: they reproduce the byte GEOMETRY of the field
;; files (straddler offset, cut position, dict nesting) without
;; carrying any of their content.

(define (zero10 n)
  (define d (number->string n))
  (string-append (make-string (- 10 (string-length d)) #\0) d))

;; assemble a classic-xref PDF from ordered (objnum . text) pairs,
;; tracking byte offsets, so every xref record is exact by construction
(define (assemble-classic-pdf objects)
  (define offsets (make-hash))
  (define out (open-output-bytes))
  (define pos 0)
  (define (emit! b)
    (write-bytes b out)
    (set! pos (+ pos (bytes-length b))))
  (emit! #"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
  (for ([o (in-list objects)])
    (hash-set! offsets (car o) pos)
    (emit! (string->bytes/utf-8 (cdr o))))
  (define max-obj (apply max (map car objects)))
  (define xref-pos pos)
  (emit! (string->bytes/utf-8
          (string-append "xref\r\n0 " (number->string (add1 max-obj))
                         "\r\n0000000000 65535 f\r\n")))
  (for ([k (in-range 1 (add1 max-obj))])
    (emit! (string->bytes/utf-8
            (if (hash-has-key? offsets k)
                (string-append (zero10 (hash-ref offsets k)) " 00000 n\r\n")
                "0000000000 65535 f\r\n"))))
  (emit! (string->bytes/utf-8
          (string-append "trailer\r\n<< /Size " (number->string (add1 max-obj))
                         " /Root 1 0 R >>\r\nstartxref\r\n"
                         (number->string xref-pos) "\r\n%%EOF\r\n")))
  (get-output-bytes out))

;; pad with spaces INSIDE an object (between tokens) to a total length
;; so the fixture controls where byte 512 falls
(define (pad-inside head tail target-len)
  (string-append
   head
   (make-string (max 0 (- target-len (string-length head)
                          (string-length tail)))
               #\space)
   tail))

;; ---- fixture 1: page straddler cut mid-reference inside /ExtGState ----
;; geometry of the blank-first-page report: obj 3 starts at 448 and byte
;; 512 falls between the object number and the generation of "/GS1 1 0 R"
(define classic-page-objs
  (list
   (cons 1 (pad-inside "1 0 obj\n<< /Type /Catalog"
                       " /Pages 2 0 R >>\nendobj\n" 85))     ; 15..100
   (cons 2 (pad-inside "2 0 obj\n<< /Type /Pages"
                       " /Kids[3 0 R 9 0 R] /Count 2 >>\nendobj\n" 348)) ; 100..448
   (cons 3 (string-append
            "3 0 obj\n<</Type/Page/Parent 2 0 R/Resources<</ExtGState<</GS1 1 "
            ;; byte 512 falls here; the tail from 512 is "0 R/GS14 ..."
            "0 R/GS14 14 0 R>>/XObject<</Im6 6 0 R>>"
            "/ProcSet[/PDF/Text/ImageB/ImageC/ImageI]>>"
            "/MediaBox[0 0 960 540] /Contents 5 0 R"
            "/Group<</Type/Group/S/Transparency/CS/DeviceRGB>>"
            "/Tabs/S/StructParents 0>>\nendobj\n"))
   (cons 5 "5 0 obj\n<< /Length 8 >>\nstream\nBT ET\nendstream\nendobj\n")
   (cons 6 "6 0 obj\n<< /Type /XObject /Subtype /Form /BBox[0 0 100 100] >>\nendobj\n")
   (cons 9 "9 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox[0 0 960 540] /Contents 5 0 R >>\nendobj\n")
   (cons 14 "14 0 obj\n<< /CA 1 >>\nendobj\n")))
(define classic-page-plain (assemble-classic-pdf classic-page-objs))
;; geometry is load-bearing: the cut must land inside the reference
(check-equal? (subbytes classic-page-plain 512 515) #"0 R")
(check-equal? (subbytes classic-page-plain 448 456) #"3 0 obj\n")

(define classic-page-wrapped (wrap-variant-c classic-page-plain))
(define classic-page (decrypt-pdf classic-page-wrapped pad))
(check-equal? (hash-ref classic-page 'coverObject) 3)
(check-equal? (hash-ref classic-page 'pages) 2)
(check-equal? (hash-ref classic-page 'xrefBad) 0)
(define cp-out (hash-ref classic-page 'bytes))
(check-equal? (bytes-length cp-out) (bytes-length classic-page-wrapped))
(define cp-3
  (subbytes cp-out 448
            (cdar (regexp-match-positions #rx#"endobj" cp-out 448))))
;; every << in the rebuilt straddler must have a matching >>: the old
;; splice closed the page dictionary early, dropping /MediaBox and
;; /Contents OUTSIDE the page object (the blank-first-page symptom)
(check-equal? (length (regexp-match* #rx#"<<" cp-3))
              (length (regexp-match* #rx#">>" cp-3)))
;; the cut fragment must heal into a name + indirect reference inside
;; the inferred /ExtGState container — not the old "/X"+"0 R" splice
(check-true
 (regexp-match? #px#"/ExtGState<<\\s*/X\\s+1\\s+0\\s+R\\s*/GS14 14 0 R>>" cp-3))
;; page-critical keys stay inside the page dictionary, verbatim
(check-true
 (regexp-match? #px#"/MediaBox\\[0 0 960 540\\] /Contents 5 0 R" cp-3))

;; ---- fixture 2: pages-tree ROOT straddler cut mid-/Kids ----
;; geometry of the D04 report: obj 2 (the /Pages root) starts at 100
;; and byte 512 falls between "3 0 " and "R" of the FIRST kid reference
(define classic-root-objs
  (list
   (cons 1 (pad-inside "1 0 obj\n<< /Type /Catalog"
                       " /Pages 2 0 R >>\nendobj\n" 85))     ; 15..100
   (cons 2 (string-append
            (pad-inside "2 0 obj\n<<" "/Type/Pages/Count 4/Kids[3 0 " 412)
            ;; byte 512 falls here; the tail from 512 is "R 5 0 R ..."
            "R 5 0 R 7 0 R 9 0 R] >>\nendobj\n"))
   (cons 3 "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox[0 0 960 540] /Contents 11 0 R >>\nendobj\n")
   (cons 5 "5 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox[0 0 960 540] /Contents 11 0 R >>\nendobj\n")
   (cons 7 "7 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox[0 0 960 540] /Contents 11 0 R >>\nendobj\n")
   (cons 9 "9 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox[0 0 960 540] /Contents 11 0 R >>\nendobj\n")
   (cons 11 "11 0 obj\n<< /Length 8 >>\nstream\nBT ET\nendstream\nendobj\n")))
(define classic-root-plain (assemble-classic-pdf classic-root-objs))
(check-equal? (subbytes classic-root-plain 512 514) #"R ")
(check-equal? (subbytes classic-root-plain 100 108) #"2 0 obj\n")
(define classic-root-wrapped (wrap-variant-c classic-root-plain))
;; pre-fix this raised "straddling object is not a page"; post-fix the
;; root rebuilds around the surviving kid references
(define classic-root
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (decrypt-pdf classic-root-wrapped pad)))
(check-true (hash? classic-root))
(when (hash? classic-root)
  (check-equal? (hash-ref classic-root 'coverObject) 2)
  (check-equal? (hash-ref classic-root 'pages) 4)
  (check-equal? (hash-ref classic-root 'xrefBad) 0)
  (define cr-out (hash-ref classic-root 'bytes))
  (check-equal? (bytes-length cr-out) (bytes-length classic-root-wrapped))
  ;; the lost head of /Kids comes back from the xref scan: all four kid
  ;; references present, the cut one healed from its lost prefix
  (define cr-2
    (subbytes cr-out 100
              (cdar (regexp-match-positions #rx#"endobj" cr-out 100))))
  (check-true
   (regexp-match? #px#"/Kids\\[\\s*3\\s+0\\s+R\\s*5 0 R 7 0 R 9 0 R\\]\\s*>>" cr-2))
  (check-true (regexp-match? #px#"/Count\\s+4\\b" cr-2))
  ;; the rebuilt catalog (head zone) points at the straddled root
  (check-true (regexp-match? #px#"/Type /Catalog /Pages 2 0 R"
                             (subbytes cr-out 15 70))))

;; ---- fixture 3: xref spot-check must reach a table >64 KiB from EOF ----
;; a 3 400-entry table (80 KiB) puts the table START beyond the old
;; 64 KiB look-back window, so the post-rebuild spot-check verified
;; NOTHING (checked=0) while the decrypt claimed success
(define filler-objs
  (for/list ([k (in-range 20 3400)])
    (cons k (format "~a 0 obj\n<< /Type /F >>\nendobj\n" k))))
(define big-xref-wrapped
  (wrap-variant-c
   (assemble-classic-pdf (append classic-page-objs filler-objs))))
(define big-xref (decrypt-pdf big-xref-wrapped pad))
(check-equal? (hash-ref big-xref 'xrefBad) 0)
(check-true (>= (hash-ref big-xref 'xrefChecked) 3000))
