#lang racket/base

(require rackunit
         racket/file
         racket/path
         file/sha1
         "../src/engine/recovery.rkt")

(check-true (valid-sha256? (make-string 64 #\a)))
(check-false (valid-sha256? "deadbeef"))
(check-false (valid-sha256? (make-string 64 #\z)))

(define source-wrapper
  (bytes-append (bytes 98 20 35 101 155 0 101 1)
                #"E-SafeNet LOCK -- synthetic bytes, not real encrypted data"))
(define exported-pdf
  #"%PDF-1.7\n1 0 obj<</Type/Catalog>>endobj\nstartxref\n0\n%%EOF\n")

(define tmp (make-temporary-file "fileboundary-recovery-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (let ([original (build-path tmp "source.pdf")]
         [exported (build-path tmp "export.pdf")]
         [still-encrypted (build-path tmp "still-locked.pdf")])
     (call-with-output-file original
       (lambda (out) (write-bytes source-wrapper out))
       #:mode 'binary #:exists 'error)
     (call-with-output-file exported
       (lambda (out) (write-bytes exported-pdf out))
       #:mode 'binary #:exists 'error)
     (call-with-output-file still-encrypted
       (lambda (out) (write-bytes source-wrapper out))
       #:mode 'binary #:exists 'error)

     (let ([report (assess-authorized-export original exported)])
       (check-equal? (hash-ref report 'verdict) "unverified")
       (check-equal? (hash-ref (hash-ref report 'source) 'classification)
                     "encrypted-recognized")
       (check-equal? (hash-ref (hash-ref report 'export) 'signature)
                     "pdf-header")
       (check-equal? (hash-ref (hash-ref report 'pdfStructureHints) 'eofMarkerSeen) #t)
       (check-equal? (hash-ref report 'trustedPlaintextSha256Comparison)
                     "notProvided")
       (check-equal? (hash-ref report 'fullFormatValidation) "notPerformed")
       (check-equal? (hash-ref report 'independentReader) "notTested")
       (check-false (hash-has-key? report 'path))
       (check-false (hash-has-key? report 'plaintext)))

     (let ([hash-of-plaintext
            (call-with-input-file exported
              (lambda (in) (bytes->hex-string (sha256-bytes in)))
              #:mode 'binary)])
       (let ([matched (assess-authorized-export
                       original exported hash-of-plaintext)]
             [mismatched (assess-authorized-export
                          original exported (make-string 64 #\0))])
         ;; Even known-hash match is not falsely marked as complete recovery.
         (check-equal? (hash-ref matched 'verdict) "unverified")
         (check-equal? (hash-ref matched 'trustedPlaintextSha256Comparison)
                       "matched")
         (check-equal? (hash-ref mismatched 'verdict) "failed")
         (check-equal? (hash-ref mismatched 'trustedPlaintextSha256Comparison)
                       "mismatched")))

     (let ([locked (assess-authorized-export original still-encrypted)])
       (check-equal? (hash-ref locked 'verdict) "failed")
       (check-equal? (hash-ref locked 'sameReadView) #t)
       (check-not-false (member "exportStillEncryptedWrapper"
                                (hash-ref locked 'reasonCodes))))
     (check-equal? (file->bytes original) source-wrapper)
     (check-equal? (file->bytes exported) exported-pdf)))
 (lambda () (delete-directory/files tmp)))
