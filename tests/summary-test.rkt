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
