#lang racket/base

;; Headless, machine-readable FileBoundary CLI.
(require json
         racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string
         "engine/inventory.rkt"
         "engine/diagnostics.rkt"
         "engine/recovery.rkt"
         "engine/update.rkt"
         "engine/decrypt.rkt")

(provide run-cli)

(define schema-version "1.0")
(define product-version "0.2.0+dev")
(define default-manifest-url
  "https://github.com/turinglambdaai/fileboundary/releases/latest/download/manifest.json")

(define-runtime-path repo-root "..")
(define default-pad-path
  (build-path repo-root "research" "t0" "pad_full.json"))

(define (coded code message)
  (hash 'code code 'message message))

(define (bad-usage)
  (values 2 "error" (hash) '()
          (list (coded "invalidArguments"
                       "Commands: version | doctor | scan <path> [--max-files N] | verify --original <file> --exported <file> [--trusted-plaintext-sha256 HEX] | decrypt --in FILE --out FILE [--pad PATH] | pad twin --plain FILE --cipher FILE --out FILE [--pad PATH] | update status | update check [--manifest URL|PATH] | update apply --package PATH --manifest PATH [--url] [--root DIR]."))))

;; decrypt: OOXML first (its CD is findable), fall back to the PDF path
(define (run-decrypt in-path out-path pad-path)
  (define pad (load-pad pad-path))
  (define ct (file->bytes in-path))
  (parse-wrapper ct)
  (define result
    (with-handlers ([exn:fail?
                     (lambda (_)
                       (define r (decrypt-pdf ct pad))
                       (hash 'kind "pdf"
                             'headRebuilt (hash-ref r 'headRebuilt)
                             'pages (hash-ref r 'pages)
                             'coverObject (hash-ref r 'coverObject)
                             'xrefChecked (hash-ref r 'xrefChecked)
                             'xrefBad (hash-ref r 'xrefBad)
                             'bytes (hash-ref r 'bytes)))])
      (define r (decrypt-ooxml ct pad))
      (hash 'kind "ooxml"
            'entries (hash-ref r 'entries)
            'verified (hash-ref r 'verified)
            'total (hash-ref r 'total)
            'bytes (hash-ref r 'bytes))))
  (with-output-to-file out-path
    (lambda () (write-bytes (hash-ref result 'bytes)))
    #:exists 'replace)
  (for/hash ([k (in-list (hash-keys result))] #:unless (equal? k 'bytes))
    (values k (hash-ref result k))))

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
    [(equal? command "decrypt")
     (let-values ([(_ flags) (split-flags rest '("--in" "--out" "--pad"))])
       (define in-path (hash-ref flags "--in" (lambda () #f)))
       (define out-path (hash-ref flags "--out" (lambda () #f)))
       (define pad-path (or (hash-ref flags "--pad" (lambda () #f))
                            default-pad-path))
       (if (and in-path out-path)
           (let ([report (run-decrypt in-path out-path pad-path)])
             (values 0 "ok"
                     (hash-set report
                               'output
                               (path->string
                                (file-name-from-path out-path)))
                     '() '()))
           (bad-usage)))]
    [(equal? command "pad")
     (pad-command rest)]
    [(equal? command "update")
     (update-command rest)]
    [else (bad-usage)]))

;; pad twin: recover the policy pad from an aligned plaintext/ciphertext
;; pair (FIELD_PROTOCOL step 2); writes a pad JSON for --out
(define (pad-command rest)
  (if (null? rest)
      (bad-usage)
      (let ([sub (car rest)] [args (cdr rest)])
        (cond
          [(equal? sub "twin")
           (let-values ([(_ flags)
                         (split-flags args '("--plain" "--cipher" "--out" "--pad"))])
             (define plain (hash-ref flags "--plain" (lambda () #f)))
             (define cipher (hash-ref flags "--cipher" (lambda () #f)))
             (define out (hash-ref flags "--out" (lambda () #f)))
             (define base-src (hash-ref flags "--pad" (lambda () #f)))
             (if (and plain cipher out)
                 (let* ([base (if base-src
                                  (load-pad base-src)
                                  (hash))]
                        [r (twin-vote (file->bytes plain)
                                      (file->bytes cipher)
                                      base)]
                        [pad (hash-ref r 'pad)]
                        [missing (hash-ref r 'missing)])
                   (with-output-to-file out
                     (lambda ()
                       (write-json
                        (hash 'schemaVersion 1
                              'kind 'policy-pad
                              'pad (for/list ([c (in-range 512)])
                                     (or (hash-ref pad c #f)
                                         (json-null)))))
                       (newline))
                     #:exists 'replace)
                   (values (if (null? missing) 0 1)
                           (if (null? missing) "ok" "partial")
                           (hash 'covered (hash-ref r 'covered)
                                 'missingCount (length missing)
                                 'output
                                 (path->string
                                  (file-name-from-path out)))
                           '()
                           (if (null? missing)
                               '()
                               (list (coded "padIncomplete"
                                            "Some pad columns are still unknown; add another twin pair.")))))
                 (bad-usage)))]
          [else (bad-usage)]))))

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
