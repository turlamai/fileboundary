#lang racket/base

;; Fixed read-only Windows diagnostics (issue #3). Never changes drivers,
;; services or processes; every family records an evidence class and the
;; elevation contract is explicit (runs, or reports requiresElevation).
(require file/sha1
         json
         racket/file
         racket/list
         racket/port
         racket/string
         "winproc.rkt")

(provide doctor-report
         run-fltmc
         classify-fltmc-result
         bounded-capture
         driver-query
         task-list
         registry-filters
         parse-registry-filters
         signature-heuristics
         probe-file!
         report->jsexpr
         write-report!)

(define capture-limit 65536)
(define timeout-seconds 8)

(define (now-ms)
  (inexact->exact (floor (current-inexact-milliseconds))))

(define (bounded-capture input)
  ;; Continue draining after the storage cap so full child pipes cannot block.
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
    ;; fltmc speaks the process UI language: Chinese Windows emits
    ;; 拒绝访问 rather than the English strings, and misclassifying
    ;; that as a generic failure hides the actual remedy.
    [(regexp-match? #rx"(?i:access is denied|requires elevation|拒绝访问|需要提升|请求的操作需要提升)"
                    combined-output)
     "requiresElevation"]
    [else "failed"]))

(define (blank-result status started)
  (hash 'status status
        'exitCode 'null
        'stdout ""
        'stderr ""
        'truncated #f
        'capturedAtUnixMs started
        'durationMs (max 0 (- (now-ms) started))))

(define (result-hash status code out err truncated? started)
  (hash 'status status
        'exitCode code
        'stdout out
        'stderr err
        'truncated truncated?
        'capturedAtUnixMs started
        'durationMs (max 0 (- (now-ms) started))))

;; Internal executor: production callers supply ONLY fltmc.exe and fixed args.
;; Synthetic commands are used exclusively by the test-support submodule.
(define (run-bounded-child executable arguments [seconds timeout-seconds])
  (define started (now-ms))
  (with-handlers ([exn:fail? (lambda (_) (blank-result "launchFailed" started))])
    ;; Some Windows subprocess configurations return a failed child status
    ;; instead of throwing for a missing executable. Distinguish launch
    ;; failure from a genuine diagnostic command failure before starting.
    (unless (file-exists? executable)
      (error 'run-bounded-child "diagnostic executable unavailable"))
    (case (system-type)
      [(windows)
       ;; GUI hosts have no console: a plain subprocess launch would
       ;; flash a black window for every console tool. winproc routes
       ;; stdio through temp files instead (CREATE_NO_WINDOW).
       (define-values (code out err timed-out?)
         (run-hidden-capture executable arguments seconds))
       (define combined (string-append out err))
       (result-hash (classify-fltmc-result code combined timed-out?)
                    code
                    (bounded-truncate out)
                    (bounded-truncate err)
                    (> (string-length combined) capture-limit)
                    started)]
      [else
       (define-values (process stdout stdin stderr)
         (apply subprocess #f #f #f executable arguments))
       (close-output-port stdin)
       (define out-value (box (hash 'text "" 'truncated #t)))
       (define err-value (box (hash 'text "" 'truncated #t)))
       ;; Drain stdout/stderr concurrently before waiting; neither pipe can starve.
       (define out-worker
         (thread (lambda () (set-box! out-value (bounded-capture stdout)))))
       (define err-worker
         (thread (lambda () (set-box! err-value (bounded-capture stderr)))))
       (define finished? (sync/timeout seconds process))
       (unless finished?
         ;; Terminate only the short-lived diagnostic child, never a filter driver.
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
                            (hash-ref err 'truncated))
             'capturedAtUnixMs started
             'durationMs (max 0 (- (now-ms) started)))])))

(define (bounded-truncate text)
  (if (> (string-length text) capture-limit)
      (substring text 0 capture-limit)
      text))

(define (run-fltmc subcommand)
  (unless (member subcommand '("filters" "instances"))
    (raise-argument-error 'run-fltmc "\"filters\" or \"instances\"" subcommand))
  (define started (now-ms))
  (cond
    [(not (eq? (system-type 'os) 'windows))
     (blank-result "unsupportedPlatform" started)]
    [else
     (define executable (find-executable-path "fltmc.exe"))
     (if (not executable)
         (blank-result "toolUnavailable" started)
         (run-bounded-child executable (list subcommand)))]))

(define (doctor-report [probe-path #f])
  (define filters (run-fltmc "filters"))
  (define instances (run-fltmc "instances"))
  (define registry (registry-filters))
  (define driver-services (driver-query))
  (define processes (task-list))
  (define heuristics
    (signature-heuristics
     (append (filter-row-names filters)
             (family-names registry 'filters))
     (family-names driver-services 'drivers)
     (family-names processes 'processes)))
  (define probe-entry
    (and probe-path
         (with-handlers ([exn:fail?
                          (lambda (_)
                            (hash 'status "failed"
                                  'path probe-path
                                  'evidence "measured"))])
           (probe-file! probe-path))))
  (define checks
    (hash 'filters filters
          'instances instances
          'registryFilters registry
          'driverServices driver-services
          'processSnapshot processes
          'signatureHeuristics heuristics))
  (define checks-with-probe
    (if probe-entry
        (hash-set checks 'probeFile probe-entry)
        checks))
  (hash 'checks checks-with-probe
        'degraded (or (not (equal? (hash-ref filters 'status) "ok"))
                      (not (equal? (hash-ref instances 'status) "ok")))
        'evidence "measured"
        'scope "read-only-diagnostics"))

;; ---------- family 6: registered filters from the registry ----------

;; Every registered filesystem filter driver carries an Altitude value
;; under Services\<name>\Instances\..., and that part of HKLM is
;; readable without elevation — unlike `fltmc filters`, which fails
;; for a plain user. This is the primary filter listing; fltmc stays
;; as the (elevation-gated) runtime view.
(define (registry-filters)
  (define started (now-ms))
  (cond
    [(not (eq? (system-type 'os) 'windows))
     (blank-result "unsupportedPlatform" started)]
    [else
     (define executable
       (or (find-executable-path "reg.exe")
           (and (file-exists? "C:/Windows/System32/reg.exe")
                (string->path "C:/Windows/System32/reg.exe"))))
     (if (not executable)
         (blank-result "toolUnavailable" started)
         (let ((r (run-bounded-child
                   executable
                   (list "query" "HKLM\\SYSTEM\\CurrentControlSet\\Services"
                         "/s" "/f" "Altitude"))))
           (define rows (parse-registry-filters (hash-ref r 'stdout "")))
           (hash-set (hash-set r 'filterCount (length rows))
                     'filters rows)))]))

;; reg query output shape: a key line
;;   HKEY_LOCAL_MACHINE\...\Services\<svc>\Instances\<inst>
;; followed by an indented "Altitude    REG_SZ    <value>" line.
;; Instances of one driver group under the service name.
(define (parse-registry-filters text)
  (define seen (make-hash))
  (define current-key #f)
  (for ([line (in-list (string-split text "\n"))])
    (cond
      [(string-prefix? (string-trim line) "HKEY_")
       (set! current-key (string-trim line))]
      [(and current-key (regexp-match? #rx"Altitude" line))
       (define m
         (regexp-match #rx"Services\\\\([^\\\\]+)\\\\Instances" current-key))
       (define parts (string-split (string-trim line) " "))
       (define alt (if (pair? parts) (last parts) ""))
       (when (and m alt (not (equal? alt "")))
         (hash-update! seen (cadr m)
                       (lambda (old) (cons alt old))
                       null))]
      [else (void)]))
  (sort
   (for/list ([(svc alts) (in-hash seen)])
     (hash 'name svc
           'altitudes (reverse (remove-duplicates alts))
           'evidence "measured"))
   string<?
   #:key (lambda (h) (hash-ref h 'name))))

;; ---------- family 2: driver / service configuration ----------

;; Fixed read-only `driverquery /fo csv`; names and state columns only.
(define (driver-query)
  (define started (now-ms))
  (cond
    [(not (eq? (system-type 'os) 'windows))
     (blank-result "unsupportedPlatform" started)]
    [else
     (define executable (find-executable-path "driverquery.exe"))
     (if (not executable)
         (blank-result "toolUnavailable" started)
         (let ((r (run-bounded-child executable (list "/fo" "csv"))))
           (define rows (csv-first-columns (hash-ref r 'stdout)))
           (hash-set (hash-set r 'driverCount (length rows))
                     'drivers rows)))]))

;; ---------- family 3: process snapshot ----------

;; Fixed read-only `tasklist /fo csv`; image names and PIDs only.
(define (task-list)
  (define started (now-ms))
  (cond
    [(not (eq? (system-type 'os) 'windows))
     (blank-result "unsupportedPlatform" started)]
    [else
     (define executable (find-executable-path "tasklist.exe"))
     (if (not executable)
         (blank-result "toolUnavailable" started)
         (let ((r (run-bounded-child executable (list "/fo" "csv"))))
           (define rows (csv-first-columns (hash-ref r 'stdout)))
           (hash-set (hash-set r 'processCount (length rows))
                     'processes rows)))]))

;; CSV rows: split on commas outside double quotes; the two fixed
;; commands emit a quoted first column (name) plus state-ish columns.
(define (csv-first-columns text)
  (for/list ([line (in-list (string-split text "\r\n"))]
             #:when (> (string-length line) 0))
    (define fields (csv-split-line line))
    (hash 'name (if (pair? fields) (car fields) line)
          'detail (if (> (length fields) 1)
                      (string-join (cdr fields) ",")
                      ""))))

(define (csv-split-line line)
  (let loop ((i 0) (cur (open-output-string)) (acc null) (in-quote? #f))
    (cond
      ((>= i (string-length line))
       (reverse (cons (get-output-string cur) acc)))
      ((equal? (string-ref line i) #\")
       (loop (add1 i) cur acc (not in-quote?)))
      ((and (equal? (string-ref line i) #\,) (not in-quote?))
       (loop (add1 i) (open-output-string)
             (cons (get-output-string cur) acc) #f))
      (else
       (write-string (substring line i (add1 i)) cur)
       (loop (add1 i) cur acc in-quote?)))))

;; ---------- family 4: signature heuristics ----------

;; Name-based matching over the collected families. ALWAYS a heuristic:
;; a matching name suggests transparent-encryption involvement and never
;; proves it. Keywords stay deliberately short and generic.
(define heuristic-keywords
  (list "esafenet" "dlp" "safedog" "huorong" "titanagent" "qax"
        ;; transparent-encryption products seen in the field; the bare
        ;; "edr" substring used to false-positive on QWAVEdrv and
        ;; WindowsTrustedRT, so it is deliberately absent
        "ahflt" "titan"))

(define (family-names family-check key)
  (if (not (hash? family-check))
      null
      (for/list ([r (in-list (hash-ref family-check key null))])
        (if (hash? r) (hash-ref r 'name "") (format "~a" r)))))

;; fltmc output is fixed-format text, not CSV: pull the filter/instance
;; names out of the captured lines for the heuristic pass.
(define (filter-row-names filters-check)
  (define text (if (hash? filters-check)
                   (hash-ref filters-check 'stdout "")
                   ""))
  (for/list ([line (in-list (string-split text "\r\n"))]
             #:when (>= (string-length (string-trim line)) 3))
    (car (string-split (string-trim line) " "))))

(define (signature-heuristics filter-names driver-names process-names)
  (define matches
    (for/list ((name (in-list (append filter-names driver-names process-names)))
               #:when (for/or ((kw (in-list heuristic-keywords)))
                 (string-contains? (string-downcase name) kw)))
      name))
  (hash 'status "ok"
        'matchedNames (remove-duplicates matches)
        'keywords heuristic-keywords
        'evidence "heuristic"))

;; ---------- family 5: probe file (opt-in) ----------

;; Writes known content to the operator-designated probe path, reads it
;; back, and records whether the content was transformed on the way
;; through any transparent-encryption layer. The only diagnostics family
;; that writes anything, and only at the explicitly supplied path.
(define (probe-file! path)
  (define started (now-ms))
  (define stamp (number->string (current-seconds)))
  (define payload (string->bytes/utf-8 (string-append "FileBoundary probe " stamp)))
  (call-with-output-file path
    (lambda (out) (write-bytes payload out))
    #:exists 'replace)
  (define read-back
    (call-with-input-file path (lambda (in) (read-bytes 4096 in)) #:mode 'binary))
  (define transformed? (not (bytes=? payload read-back)))
  (hash 'status "ok"
        'path (path->string path)
        'sizeBytes (bytes-length payload)
        'transformed transformed?
        'originalSha256 (bytes->hex-string (sha256-bytes payload))
        'readBackSha256 (bytes->hex-string (sha256-bytes read-back))
        'evidence "measured"
        'durationMs (max 0 (- (now-ms) started))))

;; ---------- report artifact (.fbreport.json) ----------

(define report-schema-version 1)

(define (report->jsexpr report)
  (hash 'schemaVersion report-schema-version
        'kind "fb-report"
        'createdUnixMs (now-ms)
        'report report))

(define (write-report! path jsexpr)
  (make-parent-directory* path)
  (with-output-to-file path
    (lambda () (write-json jsexpr) (newline))
    #:exists 'replace)
  path)

;; A separate test-only API, never referenced by the GUI or CLI.
(module+ test-support
  (provide run-bounded-child))
