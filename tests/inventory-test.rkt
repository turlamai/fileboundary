#lang racket/base

(require rackunit
         racket/file
         racket/path
         "../src/engine/inventory.rkt")

;; classification per the semantics table (docs/architecture.md): label +
;; evidence class + confidence; a header match alone never yields
;; plaintext — end-to-end structure must check out
(define-values (signature verdict evidence confidence)
  (classify-header #"%PDF-1.7"))
(check-equal? signature "pdf-header")
(check-equal? verdict "likely-encrypted") ; structure does not validate end-to-end
(check-equal? evidence "measured")
(check-equal? confidence "medium")

;; end-to-end PDF: header + %%EOF trailer = plaintext (measured)
(define-values (pdf-ok-signature pdf-ok-verdict _pdf-ok-evidence pdf-ok-confidence)
  (classify-header #"%PDF-1.7" #:tail (string->bytes/utf-8 "x%%EOF")))
(check-equal? pdf-ok-signature "pdf")
(check-equal? pdf-ok-verdict "plaintext")
(check-equal? pdf-ok-confidence "high")

(define-values (locked-signature locked-verdict locked-evidence locked-confidence)
  (classify-header
   (bytes-append (bytes 98 20 35 101 155 0 101 1)
                 #"E-SafeNet LOCK synthetic test only")))
(check-equal? locked-signature "esafenet-wrapper")
(check-equal? locked-verdict "encrypted-recognized")
(check-equal? locked-evidence "heuristic")
(check-equal? locked-confidence "high")
;; The field following the stable 4-byte wrapper magic varies by file type.
(define-values (docx-signature docx-verdict _docx-evidence _docx-confidence)
  (classify-header
   (bytes-append (bytes 98 20 35 101 188 1 68 0)
                 #"E-SafeNet LOCK synthetic DOCX wrapper")))
(check-equal? docx-signature "esafenet-wrapper")
(check-equal? docx-verdict "encrypted-recognized")
;; The prefix alone is not sufficient to claim an encrypted wrapper.
(define-values (_bare-signature bare-verdict _bare-evidence bare-confidence)
  (classify-header (bytes 98 20 35 101 188 1 68 0)))
(check-equal? bare-verdict "unknown")
(check-equal? bare-confidence "low")

;; 7z is compressed by design: high entropy proves nothing there
(define-values (sz-signature sz-verdict sz-evidence sz-confidence)
  (classify-header (bytes 55 122 188 175 39 28) #:entropy 7.9))
(check-equal? sz-signature "7z-header")
(check-equal? sz-verdict "unknown")
(check-equal? sz-confidence "low")

;; generic high-entropy payload with no known signature
(define-values (he-signature he-verdict _he-evidence he-confidence2)
  (classify-header #"ÿÿÿÿ" #:entropy 7.9))
(check-equal? he-signature "high-entropy")
(check-equal? he-verdict "likely-encrypted")
(check-equal? he-confidence2 "medium")

;; zip: header without an end-of-central-directory record = structurally
;; inconsistent with the claimed format
(define-values (zip-only-signature zip-only-verdict _zip-evidence _zip-c)
  (classify-header (bytes 80 75 3 4)))
(check-equal? zip-only-verdict "likely-encrypted")
(define-values (zip-ok-signature zip-ok-verdict _zip-ok-evidence _zip-ok-c)
  (classify-header (bytes 80 75 3 4) #:tail (bytes 80 75 5 6)))
(check-equal? zip-ok-signature "zip-ooxml")
(check-equal? zip-ok-verdict "plaintext")

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
     ;; a PDF header over an invalid body is likely-encrypted per the
     ;; semantics table (structure does not validate end-to-end)
     (check-equal? (hash-ref observed 'classification) "likely-encrypted")
     (check-equal? (hash-ref observed 'confidence) "medium")
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


;; Regression: a leaf symlink must never cause a scan to read outside its root.
;; This test intentionally creates the target in a separate temporary directory.
(define link-root (make-temporary-file "fileboundary-link-root-~a" 'directory))
(define external-root (make-temporary-file "fileboundary-external-~a" 'directory))
(define leaf-link (build-path link-root "outside.bin"))
(define directory-link (build-path link-root "linked-dir"))
(dynamic-wind
 void
 (lambda ()
   (define external (build-path external-root "private-synthetic.bin"))
   (call-with-output-file external
     (lambda (out) (write-bytes #"synthetic-outside-scan-root" out))
     #:mode 'binary #:exists 'error)
   (make-file-or-directory-link external leaf-link)
   (check-equal? (file-or-directory-type leaf-link #f) 'link)
   (check-exn exn:fail:unsafe-scan-path?
              (lambda () (inspect-file leaf-link)))
   (let-values ([(files skipped truncated?) (scan-tree link-root 10)])
     (check-equal? files '())
     (check-equal? skipped 1)
     (check-false truncated?))
   ;; The final component is a regular file, but an ancestor is a link.
   ;; Previously the path type check examined only the final component.
   (make-file-or-directory-link (path->directory-path external-root) directory-link)
   (check-exn exn:fail:unsafe-scan-path?
              (lambda () (inspect-file
                          (build-path directory-link "private-synthetic.bin"))))
   (check-exn exn:fail:unsafe-scan-path?
              (lambda () (scan-tree
                          (build-path directory-link "private-synthetic.bin")))))
 (lambda ()
   (when (link-exists? directory-link)
     (if (eq? (system-type 'os) 'windows)
         (delete-directory directory-link)
         (delete-file directory-link)))
   (when (link-exists? leaf-link) (delete-file leaf-link))
   (delete-directory/files link-root)
   (delete-directory/files external-root)))
