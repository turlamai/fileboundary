#lang racket/base

(require rackunit
         json
         racket/file
         racket/path
         racket/port
         "../src/cli.rkt")

(define (invoke args)
  (define stdout (open-output-string))
  (define code (parameterize ([current-output-port stdout])
                 (run-cli args)))
  (define body (get-output-string stdout))
  (check-equal? (length (regexp-match* #rx"\n" body)) 1)
  (values code (string->jsexpr body)))

(define-values (version-code version) (invoke '("version")))
(check-equal? version-code 0)
(check-equal? (hash-ref version 'schemaVersion) "1.0")
(check-equal? (hash-ref version 'status) "ok")
(check-equal? (hash-ref version 'command) "version")
(check-true (hash-has-key? version 'invocationId))
(check-true (hash-has-key? version 'durationMs))

(define-values (bad-code bad) (invoke '("scan")))
(check-equal? bad-code 2)
(check-equal? (hash-ref bad 'status) "error")
(check-equal? (hash-ref (car (hash-ref bad 'errors)) 'code)
              "invalidArguments")

(define-values (missing-code missing) (invoke '("scan" "missing-file-does-not-exist")))
(check-equal? missing-code 3)
(check-equal? (hash-ref (car (hash-ref missing 'errors)) 'code) "runtimeError")

(define-values (doctor-code doctor) (invoke '("doctor")))
(check-not-false (member doctor-code '(0 1)))
(check-not-false (member (hash-ref doctor 'status) '("ok" "partial")))
(check-true (hash-has-key? (hash-ref doctor 'data) 'checks))
(check-equal? (hash-ref (hash-ref doctor 'data) 'scope)
              "read-only-filter-enumeration")

(define tmp (make-temporary-file "fileboundary-cli-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (define sample (build-path tmp "fixture.bin"))
   (call-with-output-file sample
     (lambda (out) (write-bytes #"not-encrypted, not-a-pdf" out))
     #:mode 'binary #:exists 'error)
   (let-values ([(code result) (invoke (list "scan" (path->string tmp)))])
     (check-equal? code 0)
     (check-equal? (hash-ref result 'status) "ok")
     (let ([data (hash-ref result 'data)])
       (check-equal? (hash-ref data 'count) 1)
       (check-equal? (hash-ref data 'recoveryVerdict) "unverified"))
     (check-false (regexp-match? #rx"not-encrypted, not-a-pdf" (jsexpr->string result))))
   ;; A linked leaf is counted as skipped, not hashed or returned as a file.
   (let* ([outside (make-temporary-file "fileboundary-cli-external-~a")]
          [link (build-path tmp "linked-external.bin")]
          [parent-link (build-path tmp "linked-parent")])
     (dynamic-wind
    void
    (lambda ()
      (call-with-output-file outside
        (lambda (out) (write-bytes #"external-synthetic-secret" out))
        #:mode 'binary #:exists 'truncate)
      (make-file-or-directory-link outside link)
      (let-values ([(code result) (invoke (list "scan" (path->string tmp)))])
        (check-equal? code 1)
        (check-equal? (hash-ref result 'status) "partial")
        (check-equal? (hash-ref (hash-ref result 'data) 'count) 1)
        (check-equal? (hash-ref (hash-ref result 'data) 'skippedCount) 1)
        (check-equal? (hash-ref (car (hash-ref (hash-ref result 'data) 'files)) 'fileName) "fixture.bin")
        (check-equal? (hash-ref (car (hash-ref result 'warnings)) 'code) "skippedEntries")
        (check-false (regexp-match? #rx"external-synthetic-secret" (jsexpr->string result))))
      (let-values ([(code result) (invoke (list "scan" (path->string link)))])
        (check-equal? code 3)
        (check-equal? (hash-ref result 'status) "error")
        (check-equal? (hash-ref (car (hash-ref result 'errors)) 'code)
                      "unsafeScanPath")
        (check-false (regexp-match? #rx"external-synthetic-secret"
                                    (jsexpr->string result)))
        (check-false (regexp-match? (regexp (regexp-quote (path->string outside)))
                                    (jsexpr->string result))))
      ;; A regular leaf under a linked parent must also be rejected.
      (make-file-or-directory-link (path->directory-path (path-only outside))
                                   parent-link)
      (let-values ([(code result)
                    (invoke (list "scan" (path->string
                                          (build-path parent-link
                                                      (file-name-from-path outside)))))])
        (check-equal? code 3)
        (check-equal? (hash-ref result 'status) "error")
        (check-equal? (hash-ref (car (hash-ref result 'errors)) 'code)
                      "unsafeScanPath")))
    (lambda ()
      (when (link-exists? parent-link)
        (if (eq? (system-type 'os) 'windows)
            (delete-directory parent-link)
            (delete-file parent-link)))
      (when (link-exists? link) (delete-file link))
      (delete-file outside)))))
 (lambda () (delete-directory/files tmp)))

;; Authorized export verification is always evidence-based and never writes
;; decrypted content to any destination itself.
(define export-dir (make-temporary-file "fileboundary-verify-cli-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (let ([original (build-path export-dir "locked.pdf")]
         [exported (build-path export-dir "authorized-export.pdf")])
     (call-with-output-file original
       (lambda (out)
         (write-bytes (bytes-append (bytes 98 20 35 101 155 0 101 1)
                                    #"E-SafeNet LOCK synthetic") out))
       #:mode 'binary #:exists 'error)
     (call-with-output-file exported
       (lambda (out)
         (write-bytes #"%PDF-1.7\\nstartxref\\n0\\n%%EOF\\n" out))
       #:mode 'binary #:exists 'error)
     (let-values ([(code response)
                   (invoke (list "verify" "--original" (path->string original)
                                 "--exported" (path->string exported)))])
       (check-equal? code 1)
       (check-equal? (hash-ref response 'status) "partial")
       (check-equal? (hash-ref (hash-ref response 'data) 'verdict) "unverified"))
     (let-values ([(code response)
                   (invoke (list "verify" "--original" (path->string original)
                                 "--exported" (path->string original)))])
       (check-equal? code 4)
       (check-equal? (hash-ref response 'status) "error")
       (check-equal? (hash-ref (hash-ref response 'data) 'verdict) "failed"))
     (let-values ([(code response)
                   (invoke (list "verify" "--original" (path->string original)
                                 "--exported" (path->string exported)
                                 "--trusted-plaintext-sha256" "bad"))])
       (check-equal? code 2)
       (check-equal? (hash-ref response 'status) "error"))))
 (lambda () (delete-directory/files export-dir)))
