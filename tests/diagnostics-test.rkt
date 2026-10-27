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
  (check-not-false
   (member (hash-ref check 'status)
           '("ok" "requiresElevation" "toolUnavailable" "launchFailed"
             "timedOut" "failed" "unsupportedPlatform")))
  (check-true (hash-has-key? check 'exitCode))
  (check-true (hash-has-key? check 'truncated)))

;; A child process may flood stdout; the capture budget is bounded even if
;; the input stream is larger and must still be fully drained.
(define input (open-input-bytes (make-bytes 70000 65)))
(define captured (bounded-capture input))
(check-equal? (string-length (hash-ref captured 'text)) 65536)
(check-true (hash-ref captured 'truncated))
(check-true (eof-object? (read-byte input)))
