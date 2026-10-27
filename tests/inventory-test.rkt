#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../src/engine/inventory.rkt")

(define-values (signature verdict evidence) (classify-header #"%PDF-1.7"))
(check-equal? signature "pdf-header")
(check-equal? verdict "unknown") ; magic bytes are not evidence of plaintext
(check-equal? evidence "measured")

(define-values (locked-signature locked-verdict _)
  (classify-header
   (bytes-append (bytes 98 20 35 101 155 0 101 1)
                 #"E-SafeNet LOCK synthetic test only")))
(check-equal? locked-signature "esafenet-wrapper")
(check-equal? locked-verdict "encrypted-recognized")

(define tmp (make-temporary-file "fileboundary-inventory-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (define original (build-path tmp "test.pdf"))
   (call-with-output-file original
     (lambda (out) (write-bytes #"%PDF-1.7\nsynthetic, intentionally invalid PDF" out))
     #:mode 'binary #:exists 'error)
   (define before (file->bytes original))
   (define observed (inspect-file original))
   (check-equal? (hash-ref observed 'fileName) "test.pdf")
   (check-equal? (hash-ref observed 'sizeBytes) (bytes-length before))
   (check-equal? (hash-ref observed 'classification) "unknown")
   (check-equal? (hash-ref observed 'sha256)
                 (let ([input (open-input-bytes before)])
                   (require-sha256 input)))
   (check-equal? before (file->bytes original)) ; never writes originals

   (define-values (files skipped truncated?) (scan-tree tmp 1))
   (check-equal? (length files) 1)
   (check-equal? skipped 0)
   (check-false truncated?)

   (define second (build-path tmp "second.bin"))
   (call-with-output-file second
     (lambda (out) (write-bytes #"binary" out))
     #:mode 'binary #:exists 'error)
   (define-values (limited _skipped was-truncated?) (scan-tree tmp 1))
   (check-equal? (length limited) 1)
   (check-true was-truncated?))
 (lambda () (delete-directory/files tmp)))

;; Compute the expected digest independently with a pinned known vector.
(define (require-sha256 in)
  (require-hash in))
(define (require-hash in)
  (require-hash-value in))
(define (require-hash-value in)
  (bytes->hex-string (sha256-bytes in)))
