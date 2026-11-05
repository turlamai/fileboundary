#lang racket/base

(require rackunit
         (submod "../src/engine/diagnostics.rkt" test-support)
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
(check-equal? (hash-ref report 'scope) "read-only-diagnostics")
(define checks (hash-ref report 'checks))
(for ([name (in-list '(filters instances))])
  (define check (hash-ref checks name))
  (check-not-false
   (member (hash-ref check 'status)
           '("ok" "requiresElevation" "toolUnavailable" "launchFailed"
             "timedOut" "failed" "unsupportedPlatform")))
  (check-true (hash-has-key? check 'exitCode))
  (check-true (hash-has-key? check 'truncated))
  (check-true (exact-integer? (hash-ref check 'capturedAtUnixMs)))
  (check-true (exact-nonnegative-integer? (hash-ref check 'durationMs))))

;; A child process may flood stdout; the capture budget is bounded even if
;; the input stream is larger and must still be fully drained.
(define input (open-input-bytes (make-bytes 70000 65)))
(define captured (bounded-capture input))
(check-equal? (string-length (hash-ref captured 'text)) 65536)
(check-true (hash-ref captured 'truncated))
(check-true (eof-object? (read-byte input)))


(check-exn exn:fail:contract? (lambda () (run-fltmc "unload")))

;; On Windows CI, actual synthetic child processes verify concurrent capture,
;; bounded memory, explicit launch failures and enforced termination timeouts.
(when (eq? (system-type 'os) 'windows)
  (let* ([racket-exe (find-executable-path "racket.exe")]
         [success
          (run-bounded-child
           racket-exe
           (list "-e" "(begin (display \"synthetic-stdout\") (eprintf \"synthetic-stderr\"))")
           8)]
         [oversized
          (run-bounded-child
           racket-exe
           (list "-e" "(begin (display (make-string 70000 #\\x)) (eprintf \"err\"))")
           8)]
         [hung
          (run-bounded-child racket-exe (list "-e" "(sleep 10)") 0.3)]
         [unavailable
          (run-bounded-child
           (build-path (find-system-path 'temp-dir)
                       "fileboundary-intentionally-absent-command-987654321.exe")
           '() 1)])
    (check-true (path? racket-exe))
    (check-equal? (hash-ref success 'status) "ok")
    (check-equal? (hash-ref success 'stdout) "synthetic-stdout")
    (check-equal? (hash-ref success 'stderr) "synthetic-stderr")
    (check-true (exact-integer? (hash-ref success 'capturedAtUnixMs)))
    (check-equal? (hash-ref oversized 'status) "ok")
    (check-true (hash-ref oversized 'truncated))
    (check-equal? (string-length (hash-ref oversized 'stdout)) 65536)
    (check-equal? (hash-ref oversized 'stderr) "err")
    (check-equal? (hash-ref hung 'status) "timedOut")
    (check-equal? (hash-ref hung 'exitCode) 'null)
    (check-true (< (hash-ref hung 'durationMs) 5000))
    (check-equal? (hash-ref unavailable 'status) "launchFailed")))

;; Chinese-Windows fltmc output must classify as elevation, not a
;; generic failure (the operator-facing remedy depends on it)
(check-equal? (classify-fltmc-result 5 "拒绝访问。") "requiresElevation")
(check-equal? (classify-fltmc-result 5 "请求的操作需要提升。") "requiresElevation")

;; registry filter parsing: group instances per service, keep order
(define sample-reg-output
  (string-append
   "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\zdrv\\Instances\\zdrv\r\n"
   "    Altitude    REG_SZ    149000\r\n"
   "\r\n"
   "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\adrv\\Instances\\adrv\r\n"
   "    Altitude    REG_SZ    389100\r\n"
   "\r\n"
   "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\adrv\\Instances\\adrv2\r\n"
   "    Altitude    REG_SZ    389101\r\n"))
(define parsed (parse-registry-filters sample-reg-output))
(check-equal? (length parsed) 2)
(check-equal? (hash-ref (car parsed) 'name) "adrv")
(check-equal? (hash-ref (car parsed) 'altitudes) (list "389100" "389101"))
(check-equal? (hash-ref (cadr parsed) 'name) "zdrv")
(check-equal? (parse-registry-filters "") null)
