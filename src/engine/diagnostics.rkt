#lang racket/base

;; Narrow, read-only Filter Manager diagnostics. Never changes loaded filters.
(require racket/port)

(provide doctor-report
         run-fltmc
         classify-fltmc-result
         bounded-capture)

(define capture-limit 65536)
(define timeout-seconds 8)

(define (bounded-capture input)
  ;; Continue draining even beyond the storage cap to prevent a full-pipe deadlock.
  (define collected (open-output-bytes))
  (define kept 0)
  (define truncated? #f)
  (let loop ()
    (define chunk (read-bytes 4096 input))
    (unless (eof-object? chunk)
      (define amount (min (bytes-length chunk) (max 0 (- capture-limit kept))))
      (when (> amount 0)
        (write-bytes chunk collected 0 amount)
        (set! kept (+ kept amount)))
      (when (< amount (bytes-length chunk))
        (set! truncated? #t))
      (loop)))
  (hash 'text (bytes->string/latin-1 (get-output-bytes collected))
        'truncated truncated?))

(define (classify-fltmc-result exit-code combined-output [timed-out? #f])
  (cond
    [timed-out? "timedOut"]
    [(and (exact-integer? exit-code) (zero? exit-code)) "ok"]
    [(regexp-match? #rx"(?i:access is denied|requires elevation)" combined-output)
     "requiresElevation"]
    [else "failed"]))

(define (run-fltmc subcommand)
  (unless (member subcommand '("filters" "instances"))
    (raise-argument-error 'run-fltmc "\"filters\" or \"instances\"" subcommand))
  (cond
    [(not (eq? (system-type 'os) 'windows))
     (hash 'status "unsupportedPlatform" 'exitCode 'null
           'stdout "" 'stderr "" 'truncated #f)]
    [else
     (define executable (find-executable-path "fltmc.exe"))
     (if (not executable)
         (hash 'status "toolUnavailable" 'exitCode 'null
               'stdout "" 'stderr "" 'truncated #f)
         (with-handlers ([exn:fail?
                          (lambda (_)
                            (hash 'status "launchFailed" 'exitCode 'null
                                  'stdout "" 'stderr "" 'truncated #f))])
           (define-values (process stdout stdin stderr)
             (subprocess #f #f #f executable subcommand))
           (close-output-port stdin)
           (define out-value (box (hash 'text "" 'truncated #t)))
           (define err-value (box (hash 'text "" 'truncated #t)))
           ;; Both streams are drained concurrently, not sequentially.
           (define out-worker
             (thread (lambda () (set-box! out-value (bounded-capture stdout)))))
           (define err-worker
             (thread (lambda () (set-box! err-value (bounded-capture stderr)))))
           (define finished? (sync/timeout timeout-seconds process))
           (unless finished?
             ;; This terminates only our fltmc.exe child, never a filter driver.
             (subprocess-kill process #t))
           (subprocess-wait process)
           (unless (sync/timeout 2 out-worker)
             (close-input-port stdout)
             (kill-thread out-worker))
           (unless (sync/timeout 2 err-worker)
             (close-input-port stderr)
             (kill-thread err-worker))
           (unless (port-closed? stdout) (close-input-port stdout))
           (unless (port-closed? stderr) (close-input-port stderr))
           (define out (unbox out-value))
           (define err (unbox err-value))
           (define code (if finished? (subprocess-status process) 'null))
           (hash 'status (classify-fltmc-result
                          code
                          (string-append (hash-ref out 'text)
                                         (hash-ref err 'text))
                          (not finished?))
                 'exitCode code
                 'stdout (hash-ref out 'text)
                 'stderr (hash-ref err 'text)
                 'truncated (or (hash-ref out 'truncated)
                                (hash-ref err 'truncated)))))]))

(define (doctor-report)
  (define filters (run-fltmc "filters"))
  (define instances (run-fltmc "instances"))
  (hash 'checks (hash 'filters filters 'instances instances)
        'degraded (or (not (equal? (hash-ref filters 'status) "ok"))
                      (not (equal? (hash-ref instances 'status) "ok")))
        'evidence "measured"
        'scope "read-only-filter-enumeration"))
