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
   (let* ([before (file->bytes original)]
          [observed (inspect-file original)])
     (check-equal? (hash-ref observed 'fileName) "test.pdf")
     (check-equal? (hash-ref observed 'sizeBytes) (bytes-length before))
     (check-equal? (hash-ref observed 'classification) "unknown")
     (check-equal? (hash-ref observed 'sha256)
                   "8d5c2a3f60418620f9758335e196081510e61c173f4f450146b87e50c5932a20")
     (check-equal? before (file->bytes original))) ; never writes originals

   (let-values ([(files skipped truncated?) (scan-tree tmp 1)])
     (check-equal? (length files) 1)
     (check-equal? skipped 0)
     (check-false truncated?))

   (let ([second (build-path tmp "second.bin")])
     (call-with-output-file second
       (lambda (out) (write-bytes #"binary" out))
       #:mode 'binary #:exists 'error))
   (let-values ([(limited _skipped was-truncated?) (scan-tree tmp 1)])
     (check-equal? (length limited) 1)
     (check-true was-truncated?)))
 (lambda () (delete-directory/files tmp)))
