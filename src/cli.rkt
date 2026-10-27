#lang racket/base

;; Headless, machine-readable FileBoundary CLI.
(require json
         racket/list
         "engine/inventory.rkt")

(provide run-cli)

(define schema-version "1.0")
(define product-version "0.1.0-dev")

(define (coded code message)
  (hash 'code code 'message message))

(define (bad-usage)
  (values 2 "error" (hash) '()
          (list (coded "invalidArguments"
                       "Use version or scan <file-or-directory> [--max-files N]."))))

(define (dispatch args)
  (define command (if (null? args) "" (car args)))
  (define rest (if (null? args) '() (cdr args)))
  (cond
    [(equal? command "version")
     (if (null? rest)
         (values 0 "ok"
                 (hash 'version product-version
                       'runtime "Racket CS"
                       'interface "headless"
                       'schemaVersion schema-version)
                 '() '())
         (bad-usage))]
    [(equal? command "scan")
     (let ([max-files
       (cond
         [(= (length rest) 1) 1000]
         [(and (= (length rest) 3)
               (equal? (cadr rest) "--max-files"))
          (string->number (caddr rest))]
         [else #f])])
       (if (and max-files
              (exact-integer? max-files)
              (<= 1 max-files 100000))
         (let-values ([(files skipped truncated?)
                       (scan-tree (car rest) max-files)])
           (define warnings
             (append (if (> skipped 0)
                         (list (coded "skippedEntries"
                                      "Some entries were inaccessible or filesystem links."))
                         '())
                     (if truncated?
                         (list (coded "limitReached"
                                      "Scan stopped at the configured max-files limit."))
                         '())))
           (values (if (null? warnings) 0 1)
                   (if (null? warnings) "ok" "partial")
                   (hash 'files files
                         'count (length files)
                         'skippedCount skipped
                         'truncated truncated?
                         'readView "current-process"
                         'recoveryVerdict "unverified")
                   warnings '()))
         (bad-usage)))]
    [(or (equal? command "doctor") (equal? command "verify"))
     (values 3 "error" (hash) '()
             (list (coded "notImplemented"
                          "This command is planned but not implemented in this vertical slice.")))]
    [else (bad-usage)]))

(define (run-cli args)
  (define started (current-inexact-milliseconds))
  (define command (if (null? args) "help" (car args)))
  (define-values (code status data warnings errors)
    (with-handlers ([exn:fail?
                     (lambda (_)
                       ;; Do not leak private paths or OS details to stdout.
                       (values 3 "error" (hash) '()
                               (list (coded "runtimeError"
                                            "Operation failed. Check local path and permissions."))) )])
      (dispatch args)))
  (write-json
   (hash 'schemaVersion schema-version
         'command command
         'invocationId (format "~x-~x"
                               (inexact->exact (floor started))
                               (random 1000000000))
         'status status
         'data data
         'warnings warnings
         'errors errors
         'durationMs (max 0 (inexact->exact
                             (round (- (current-inexact-milliseconds)
                                       started)))))
   (current-output-port))
  (newline)
  code)

(module+ main
  (exit (run-cli (vector->list (current-command-line-arguments)))))
