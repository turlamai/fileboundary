#lang racket/base

(require rackunit
         (submod "../src/engine/diagnostics.rkt" test-support)
         "../src/engine/diagnostics.rkt"
         "../src/engine/winproc.rkt")

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
;; The registry listing is the primary filter inventory: on Windows it
;; comes from the registry API (no child process) and carries the Group.
(define registry-check (hash-ref checks 'registryFilters))
(when (eq? (system-type 'os) 'windows)
  (check-equal? (hash-ref registry-check 'status) "ok")
  (check-equal? (hash-ref registry-check 'source) "registry-api")
  (check-true (pair? (hash-ref registry-check 'filters)))
  (for ([row (in-list (hash-ref registry-check 'filters))])
    (check-true (hash-has-key? row 'group))
    (check-true (hash-has-key? row 'start))))
(check-true (list? (hash-ref (hash-ref checks 'signatureHeuristics) 'encryptionGroup)))

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
          (run-bounded-child racket-exe (list "-e" "(sleep 10)") 1.0)]
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
    ;; a timed-out child is terminated, so the code is whatever the
;; terminator passed (1); the POSIX path never retrieves it ('null)
(check-true (or (equal? (hash-ref hung 'exitCode) 'null)
                (exact-integer? (hash-ref hung 'exitCode))))
    (check-true (< (hash-ref hung 'durationMs) 5000))
    (check-equal? (hash-ref unavailable 'status) "launchFailed")))

;; Chinese-Windows fltmc output must classify as elevation, not a
;; generic failure (the operator-facing remedy depends on it)
(check-equal? (classify-fltmc-result 5 "拒绝访问。") "requiresElevation")
(check-equal? (classify-fltmc-result 5 "请求的操作需要提升。") "requiresElevation")
;; `fltmc instances` exits 0 on a denied query (measured on Windows 11
;; 24H2) and the message is GBK on Chinese Windows, which the latin-1
;; capture turns into mojibake. The HRESULT is the only language- and
;; exit-code-independent evidence, so it must win in every combination.
(check-equal? (classify-fltmc-result 0
                                  "\r\n筛选器实例列表失败，出现错误: 0x80070005\r\n")
              "requiresElevation")
(check-equal? (classify-fltmc-result 0 "Filter list failed with error: 0x80070005")
              "requiresElevation")
(check-equal? (classify-fltmc-result 1 "\r\nÉ¸Ñ¡Æ÷ÁÐ±íÊ§°Ü£¬³öÏÖ´íÎó: 0x80070005")
              "requiresElevation")
(check-equal? (classify-fltmc-result 0 "") "ok")

;; Console tools emit the ANSI code page; on a Chinese system the captured
;; GBK bytes of 拒绝访问 must decode to it (the latin-1 capture made every
;; message pattern miss). UTF-8 children pass through untouched.
(check-equal? (decode-console-bytes (string->bytes/utf-8 "路径 ok")) "路径 ok")
(when (and (eq? (system-type 'os) 'windows)
           (regexp-match? #px"^zh" (system-language+country)))
  (check-equal? (decode-console-bytes (bytes #xbe #xdc #xbe #xf8 #xb7 #xc3 #xce #xca))
                "拒绝访问"))

;; fltmc's header and rule lines are not filter names and must not reach
;; the keyword pass.
(check-equal?
 (filter-row-names
  (hash 'stdout (string-append
                 "Filter Name                 Num Instances    Max Instance    Altitude      Frame\r\n"
                 "-------------------------  -------------    ------------    --------      -----\r\n"
                 "TsdEncryptMF               1                1               149998.1       0\r\n")))
 '("TsdEncryptMF"))

;; The service Group is the authoritative encryption-class signal; names
;; only add hints.
(define group-rows
  (list (hash 'name "TsdEncryptMF" 'altitudes '("149998.1") 'group "FSFilter Encryption" 'start 1)
        (hash 'name "WdFilter" 'altitudes '("328010") 'group "FSFilter Anti-Virus" 'start 3)
        (hash 'name "eeCtrl" 'altitudes '("329010") 'group #f 'start 1)))
(check-equal? (encryption-group-filters group-rows) '("TsdEncryptMF"))
(check-equal? (encryption-group-filters '()) '())

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
