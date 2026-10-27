#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/string
         "../src/engine/summary.rkt")

(define (record kind)
  (hash 'classification kind))

(check-equal? (scan-statistics '())
              (hash 'total 0 'recognizedWrapper 0 'other 0))
(check-equal?
 (scan-statistics (list (record "encrypted-recognized")
                        (record "unknown")
                        (record "encrypted-recognized")))
 (hash 'total 3 'recognizedWrapper 2 'other 1))

(define root (make-temporary-file "fileboundary-gui-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (call-with-output-file (build-path root "sample.pdf")
     (lambda (out) (write-bytes #"%PDF-1.7\nSynthetic invalid PDF" out))
     #:mode 'binary #:exists 'error)
   (let ([message (scan-summary (path->string root) #:max-files 5)])
     (check-true (string-contains? message "Inspected: 1 file"))
     (check-true (string-contains? message "Signatures do not prove plaintext"))
     (check-false (string-contains? message (path->string root)))))
 (lambda () (delete-directory/files root)))

(define verify-root (make-temporary-file "fileboundary-verify-gui-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (let ([original (build-path verify-root "encrypted-sample.pdf")]
         [candidate (build-path verify-root "approved-export.pdf")])
     (call-with-output-file original
       (lambda (out)
         (write-bytes
          (bytes-append (bytes 98 20 35 101 188 1 68 0)
                        #"E-SafeNet LOCK synthetic") out))
       #:mode 'binary #:exists 'error)
     (call-with-output-file candidate
       (lambda (out)
         (write-bytes #"%PDF-1.7\nstartxref\n0\n%%EOF\n" out))
       #:mode 'binary #:exists 'error)
     (let ([result (verify-export-summary (path->string original)
                                          (path->string candidate))])
       (check-true (string-contains? result "UNVERIFIED"))
       (check-true (string-contains? result "No decryption performed"))
       (check-false (string-contains? result (path->string verify-root))))
     (let ([result (verify-export-summary (path->string original)
                                          (path->string original))])
       (check-true (string-contains? result "FAILED"))
       (check-true (string-contains? result "exportStillEncryptedWrapper")))))
 (lambda () (delete-directory/files verify-root)))
