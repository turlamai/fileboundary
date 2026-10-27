#lang racket/base

(require rackunit
         json
         racket/file
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
     (check-false (regexp-match? #rx"not-encrypted, not-a-pdf" (jsexpr->string result)))))
 (lambda () (delete-directory/files tmp)))
