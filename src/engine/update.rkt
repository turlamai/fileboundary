#lang racket/base

;; Update engine (ADR-0008): release manifest handling, version compare,
;; full/delta package application. All network use is explicit and
;; operator-initiated; every function here is deterministic except
;; fetch-manifest/download-file!, which are only called by the CLI's
;; explicit update commands.

(require json
         file/unzip
         racket/file
         racket/format
         racket/list
         racket/port
         racket/string
         racket/path
         net/url
         "sha256.rkt")

(provide parse-version
         version<? version=? version->string
         parse-manifest
         check-update
         sha256-file
         fetch-manifest
         download-file!
         apply-package
         default-install-root
         installed-version
         set-current-version!)

(define (unzip-into! zip-path dest-dir)
  (unzip zip-path (make-filesystem-entry-reader #:dest dest-dir)))

;; ---------- versions ----------

;; "0.2.0" or "0.2.0+abc1234" -> (values '(0 2 0) "abc1234" or #f)
(define (parse-version v)
  (unless (string? v)
    (raise-argument-error 'parse-version "string?" v))
  (define parts (string-split v "+"))
  (define nums (map (lambda (s) (string->number s))
                    (string-split (car parts) ".")))
  (unless (and (= (length nums) 3) (andmap (lambda (n) (and n (exact-integer? n) (>= n 0))) nums))
    (raise-argument-error 'parse-version "X.Y.Z[+commit]" v))
  (values nums (and (= (length parts) 2) (cadr parts))))

(define (version->string nums commit)
  (string-append (string-join (map number->string nums) ".")
                 (if commit (string-append "+" commit) "")))

(define (version<? a b)
  (define-values (pa ca) (parse-version a))
  (define-values (pb cb) (parse-version b))
  (cond [(< (car pa) (car pb)) #t]
        [(> (car pa) (car pb)) #f]
        [(< (cadr pa) (cadr pb)) #t]
        [(> (cadr pa) (cadr pb)) #f]
        [(< (caddr pa) (caddr pb)) #t]
        [else #f]))

(define (version=? a b)
  (define-values (pa ca) (parse-version a))
  (define-values (pb cb) (parse-version b))
  (equal? pa pb))

;; ---------- manifest ----------

(define (hex-string-64? v) (and (string? v) (= (string-length v) 64)))

;; validate + normalize a manifest jsexpr; raises on schema violations
(define (parse-manifest j)
  (unless (hash? j)
    (raise-argument-error 'parse-manifest "jsexpr hash?" j))
  (define (req key pred)
    (define v (hash-ref j key (lambda () (error 'parse-manifest "missing field: ~a" key))))
    (unless (pred v) (error 'parse-manifest "bad field: ~a" key))
    v)
  (req 'schemaVersion (lambda (v) (equal? v 1)))
  (req 'channel string?)
  (define version (req 'version string?))
  (parse-version version)
  (req 'commit string?)
  (define pkg (req 'package hash?))
  (hash-ref pkg 'kind (lambda () (error 'parse-manifest "missing: package.kind")))
  (hash-ref pkg 'name (lambda () (error 'parse-manifest "missing: package.name")))
  (unless (exact-positive-integer? (hash-ref pkg 'bytes (lambda () (error 'parse-manifest "missing: package.bytes"))))
    (error 'parse-manifest "bad: package.bytes"))
  (unless (hex-string-64? (hash-ref pkg 'sha256 (lambda () (error 'parse-manifest "missing: package.sha256"))))
    (error 'parse-manifest "bad: package.sha256"))
  (hash-ref pkg 'url (lambda () (error 'parse-manifest "missing: package.url")))
  (unless (hash-has-key? j 'deltas)
    (error 'parse-manifest "missing field: deltas"))
  (for ([d (in-list (hash-ref j 'deltas))])
    (unless (hash? d) (error 'parse-manifest "bad deltas entry"))
    (parse-version (hash-ref d 'baseVersion (lambda () (error 'parse-manifest "missing: delta.baseVersion"))))
    (unless (hex-string-64? (hash-ref d 'sha256 (lambda () (error 'parse-manifest "missing: delta.sha256"))))
      (error 'parse-manifest "bad: delta.sha256")))
  j)

(define (fetch-manifest source)
  (define j
    (cond [(or (string-prefix? source "http://") (string-prefix? source "https://"))
           (define in (get-pure-port (string->url source) #:redirections 5))
           (define body (port->bytes in))
           (close-input-port in)
           (with-input-from-bytes body read-json)]
          [else
           (with-input-from-file source read-json)]))
  (parse-manifest j))

;; ---------- check ----------

;; returns a hash: action = "none" | "update"
(define (check-update manifest current-version)
  (define latest (hash-ref manifest 'version))
  (define pkg (hash-ref manifest 'package))
  (if (version<? current-version latest)
      (hash 'action "update"
            'currentVersion current-version
            'latestVersion latest
            'commit (hash-ref manifest 'commit)
            'package pkg
            'deltas (for/list ([d (in-list (hash-ref manifest 'deltas))]
                               #:when (equal? (hash-ref d 'baseVersion)
                                              current-version))
                      d))
      (hash 'action "none"
            'currentVersion current-version
            'latestVersion latest)))

;; ---------- apply ----------

(define (default-install-root)
  (define local (getenv "LOCALAPPDATA"))
  (if local
      (path->string (build-path local "FileBoundary"))
      (path->string (build-path (find-system-path 'home-dir) ".fileboundary"))))

(define (installed-version root)
  (define marker (build-path root "current.txt"))
  (if (file-exists? marker)
      (string-trim (file->string marker))
      #f))

(define (set-current-version! root version)
  (make-directory* root)
  (define marker (build-path root "current.txt"))
  (define tmp (build-path root (string-append "current.txt.tmp."
                                              (number->string (current-milliseconds)))))
  (with-output-to-file tmp (lambda () (displayln version)) #:exists 'replace)
  (rename-file-or-directory tmp marker #t))

;; verify a package against its manifest entry, then apply.
;; kind "full": zip must contain manifest.json with the target file table;
;; every extracted file is hash-verified before current is bumped.
;; kind "delta": zip contains delta.json + payload/; every replace/delete
;; guard must match the installed tree, else the delta is rejected.
(define (apply-package package-path pkg-meta install-root)
  (define actual (sha256-file package-path))
  (define expected (hash-ref pkg-meta 'sha256))
  (unless (string=? actual expected)
    (error 'apply-package "package hash mismatch: expected ~a got ~a"
           expected actual))
  (define kind (hash-ref pkg-meta 'kind))
  (define tmp-dir (make-temporary-file "fb-update-~a" 'directory))
  (dynamic-wind
    (lambda () (unzip-into! package-path tmp-dir))
    (lambda ()
      (case kind
        [("full") (apply-full tmp-dir install-root)]
        [("delta") (apply-delta tmp-dir install-root)]
        [else (error 'apply-package "unknown package kind: ~a" kind)]))
    (lambda ()
      (delete-directory/files tmp-dir #:must-exist? #f))))

(define (read-json-file p)
  (with-input-from-file p read-json))

(define (verify-table! table dir)
  ;; table: hash of {"version":..., "files": [{path, sha256}]}; every
  ;; listed file must exist under dir with the exact hash; unexpected
  ;; files in the package are a packaging error.
  (define files (hash-ref table 'files))
  (define expected (make-hash))
  (for ([f files])
    (hash-set! expected (hash-ref f 'path) (hash-ref f 'sha256)))
  (for ([(rel want) expected])
    (define p (build-path dir (string->path rel)))
    (unless (file-exists? p)
      (error 'verify-table! "missing file after extract: ~a" rel))
    (define got (sha256-file p))
    (unless (string=? got want)
      (error 'verify-table! "hash mismatch after extract: ~a" rel)))
  (for ([p (in-directory dir)])
    (unless (directory-exists? p)
      (define rel
        (string-replace
         (path->string (find-relative-path dir p)) "\\" "/"))
      (when (and (not (hash-has-key? expected rel))
                 (not (equal? rel "filetable.json"))
                 (not (equal? rel "manifest.json")))
        (error 'verify-table! "unexpected file in package: ~a" rel)))))

(define (apply-full tmp-dir install-root)
  (define tpath (build-path tmp-dir "filetable.json"))
  (unless (file-exists? tpath)
    (error 'apply-full "package has no embedded filetable.json"))
  (define table (read-json-file tpath))
  (define version (hash-ref table 'version))
  (verify-table! table tmp-dir)
  (define target (build-path install-root "releases" version))
  (when (directory-exists? target)
    (delete-directory/files target))
  (make-directory* target)
  (for ([p (in-directory tmp-dir)]
        #:unless (directory-exists? p))
    (define rel
      (string-replace (path->string (find-relative-path tmp-dir p)) "\\" "/"))
    (define dst (build-path target (string->path rel)))
    (make-directory* (path-only dst))
    (copy-file p dst))
  (set-current-version! install-root version)
  version)

(define (apply-delta tmp-dir install-root)
  (define spec (read-json-file (build-path tmp-dir "delta.json")))
  (define base-version (hash-ref spec 'baseVersion))
  (define target-version (hash-ref spec 'targetVersion))
  (unless (equal? (installed-version install-root) base-version)
    (error 'apply-delta "delta base ~a does not match installed ~a"
           base-version (installed-version install-root)))
  (define ops (hash-ref spec 'operations))
  ;; guard pass: every replace/delete must see the recorded base hash
  (for ([op ops])
    (define action (hash-ref op 'action))
    (define rel (hash-ref op 'path))
    (define p (build-path install-root rel))
    (case action
      [("replace" "delete")
       (unless (file-exists? p)
         (error 'apply-delta "guard failed (missing): ~a" rel))
       (define got (sha256-file p))
       (unless (string=? got (hash-ref op 'baseSha256))
         (error 'apply-delta "guard failed (hash): ~a" rel))]
      [("add") (void)]
      [else (error 'apply-delta "unknown delta action: ~a" action)]))
  ;; apply pass
  (for ([op ops])
    (define action (hash-ref op 'action))
    (define rel (hash-ref op 'path))
    (define p (build-path install-root rel))
    (case action
      [("delete") (when (file-exists? p) (delete-file p))]
      [("add" "replace")
       (define payload (build-path tmp-dir "payload" rel))
       (unless (file-exists? payload)
         (error 'apply-delta "delta payload missing: ~a" rel))
       (define got (sha256-file payload))
       (unless (string=? got (hash-ref op 'sha256))
         (error 'apply-delta "payload hash mismatch: ~a" rel))
       (make-directory* (path-only p))
       (copy-file payload p #:exists-ok? #t)]))
  (set-current-version! install-root target-version)
  target-version)

;; ---------- download ----------

(define (download-file! url dest)
  (define in (get-pure-port (string->url url) #:redirections 5))
  (define body (port->bytes in))
  (close-input-port in)
  (display-to-file body dest #:exists 'replace)
  dest)
