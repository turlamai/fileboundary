#lang racket/base

(require rackunit
         "../src/engine/diagnostics.rkt")

(check-equal? (classify-fltmc-result 0 "") "ok")
(check-equal? (classify-fltmc-result 1 "Access is denied.")
              "requiresElevation")
(check-equal? (classify-fltmc-result 5 "Requires elevation")
              "requiresElevation")
(check-equal? (classify-fltmc-result 5 "Other diagnostic failure")
              "failed")
(check-equal? (classify-fltmc-result 5 "" #t) "timedOut")

;; These checks run on Windows in CI, but must degrade explicitly elsewhere.
(define report (doctor-report))
(check-true (hash-has-key? report 'checks))
(check-equal? (hash-ref report 'scope) "read-only-filter-enumeration")
(define checks (hash-ref report 'checks))
(for ([name (in-list '(filters instances))])
  (define check (hash-ref checks name))
  (check-true
   (member (hash-ref check 'status)
           '("ok" "requiresElevation" "toolUnavailable" "launchFailed"
             "timedOut" "failed" "unsupportedPlatform")))
  (check-true (hash-has-key? check 'exitCode))
  (check-true (hash-has-key? check 'truncated)))
