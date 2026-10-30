#lang racket/base

;; Headless, machine-readable FileBoundary CLI.
(require json
         racket/file
         racket/list
         racket/string
         "engine/inventory.rkt"
         "engine/diagnostics.rkt"
         "engine/recovery.rkt"
         "engine/update.rkt")

(provide run-cli)

(define schema-version "1.0")
(define product-version "0.1.0+dev")
(define default-manifest-url
  "https://github.com/turinglambdaai/fileboundary/releases/latest/download/manifest.json")

(define (coded code message)
  (hash 'code code 'message message))

(define (bad-usage)
  (values 2 "error" (hash) '()
          (list (coded "invalidArguments"
                       "Commands: version | doctor | scan <path> [--max-files N] | verify --original <file> --exported <file> [--trusted-plaintext-sha256 HEX] | update status | update check [--manifest URL|PATH] | update apply --package PATH --manifest PATH [--url] [--root DIR]."))))

;; flag parse helper: returns (values positionals flags); flags with values
;; are listed in known-value-flags, all other "--x" become boolean flags
(define (split-flags args known-value-flags)
  (let loop ([xs args] [pos '()] [flags (hash)])
    (cond
      [(null? xs) (values (reverse pos) flags)]
      [(and (string-prefix? (car xs) "--")
            (member (car xs) known-value-flags))
       (if (null? (cdr xs))
           (loop (cdr xs) pos (hash-set flags (car xs) #f))
           (loop (cddr xs) pos (hash-set flags (car xs) (cadr xs))))]
      [(string-prefix? (car xs) "--")
       (loop (cdr xs) pos (hash-set flags (car xs) #t))]
      [else (loop (cdr xs) (cons (car xs) pos) flags)])))

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
    [(equal? command "update")
     (update-command rest)]
    [else (bad-usage)]))

;; update subcommand: status | check | apply. Network use is explicit:
;; check hits the manifest URL only when asked (default channel URL),
;; apply reads local files unless --url is given for the package.
(define (update-command rest)
  (if (null? rest)
      (bad-usage)
      (let ([sub (car rest)] [args (cdr rest)])
        (cond
          [(equal? sub "status")
           (values 0 "ok"
                   (hash 'runningVersion product-version
                         'installedVersion (installed-version
                                            (default-install-root))
                         'installRoot (default-install-root))
                   '() '())]
          [(equal? sub "check")
           (let-values ([(_pos flags)
                         (split-flags args '("--manifest"))])
             (define source (or (hash-ref flags "--manifest" (lambda () #f))
                                default-manifest-url))
             (define manifest (fetch-manifest source))
             (define result (check-update manifest product-version))
             (define available? (equal? (hash-ref result 'action) "update"))
             (values 0 "ok"
                     (hash 'updateAvailable available?
                           'currentVersion (hash-ref result 'currentVersion)
                           'latestVersion (hash-ref result 'latestVersion)
                           'package (hash-ref result 'package (lambda () (hash)))
                           'deltas (hash-ref result 'deltas (lambda () '())))
                     '() '()))]
          [(equal? sub "apply")
           (let-values ([(_ flags) (split-flags args '("--package" "--manifest" "--root" "--url"))])
             (define package (hash-ref flags "--package" (lambda () #f)))
             (define manifest-src (hash-ref flags "--manifest" (lambda () #f)))
             (define url (hash-ref flags "--url" (lambda () #f)))
             (define root (or (hash-ref flags "--root" (lambda () #f))
                              (default-install-root)))
             (cond
               [(not package)
                (bad-usage)]
               [(and url (not (or (string-prefix? url "https://")
                                  (string-prefix? url "http://"))))
                (values 2 "error" (hash) '()
                        (list (coded "invalidArguments"
                                     "--url must be an http(s) URL.")))]
               [(not manifest-src)
                (bad-usage)]
               [else
                (define manifest (fetch-manifest manifest-src))
                (define pkg-meta (hash-ref manifest 'package))
                (define tmp (make-temporary-file "fb-pkg-~a.zip"))
                (dynamic-wind
                  (lambda ()
                    (if url
                        (download-file! url tmp)
                        (copy-file package tmp #:exists-ok? #t)))
                  (lambda ()
                    (define version (apply-package tmp pkg-meta root))
                    (values 0 "ok"
                            (hash 'appliedVersion version
                                  'kind (hash-ref pkg-meta 'kind)
                                  'root root)
                            '() '()))
                  (lambda ()
                    (with-handlers ([exn:fail? void]) (delete-file tmp))))]))]
          [else (bad-usage)]))))

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
