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
