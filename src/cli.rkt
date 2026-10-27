#lang racket/base

;; Headless, machine-readable FileBoundary CLI.
(require json
         racket/list
         "engine/inventory.rkt"
         "engine/diagnostics.rkt"
         "engine/recovery.rkt")

(provide run-cli)

(define schema-version "1.0")
(define product-version "0.1.0-dev")

(define (coded code message)
  (hash 'code code 'message message))

(define (bad-usage)
  (values 2 "error" (hash) '()
          (list (coded "invalidArguments"
                       "Commands: version | doctor | scan <path> [--max-files N] | verify --original <file> --exported <file> [--trusted-plaintext-sha256 HEX]."))))

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
    [(equal? command "doctor")
     (if (null? rest)
         (let* ([report (doctor-report)]
                [degraded? (hash-ref report 'degraded)]
                [warnings
                 (if degraded?
                     (list (coded "diagnosticsIncomplete"
                                  "One or more read-only checks could not complete; inspect per-check status."))
                     '())])
           (values (if degraded? 1 0)
                   (if degraded? "partial" "ok")
                   report warnings '()))
         (bad-usage))]
    [(equal? command "verify")
     (let ([valid?
            (and (member (length rest) '(4 6))
                 (equal? (list-ref rest 0) "--original")
                 (equal? (list-ref rest 2) "--exported")
                 (or (= (length rest) 4)
                     (and (equal? (list-ref rest 4) "--trusted-plaintext-sha256")
                          (valid-sha256? (list-ref rest 5)))))])
       (if valid?
           (let* ([baseline (if (= (length rest) 6) (list-ref rest 5) #f)]
                  [report (assess-authorized-export
                           (list-ref rest 1) (list-ref rest 3) baseline)]
                  [failed? (equal? (hash-ref report 'verdict) "failed")])
             (if failed?
                 (values 4 "error" report '()
                         (list (coded "verificationFailed"
                                      "The authorized export is still wrapped or mismatches the trusted plaintext digest.")))
                 (values 1 "partial" report
                         (list (coded "verificationIncomplete"
                                      "Export comparison is not decryption or independent structural/reader verification."))
                         '())))
           (bad-usage)))]
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
