#lang racket/base

;; Read-only evidence collection. A recognizable signature is NOT plaintext validation.
(require file/sha1
         json
         racket/file
         racket/list
         racket/path)

(provide inspect-file scan-tree scan-tree/resume classify-header manifest->prior-table
         exn:fail:unsafe-scan-path?
         manifest->jsexpr write-manifest! read-manifest)

(define (starts-with-bytes? input prefix)
  (and (>= (bytes-length input) (bytes-length prefix))
       (bytes=? (subbytes input 0 (bytes-length prefix)) prefix)))

(define (classify-header header)
  (cond
    ;; The first four bytes are stable across the controlled PDF/DOCX pair.
    ;; Bytes 4-7 vary between specimens; require both ASCII markers as well.
    [(and (starts-with-bytes? header (bytes 98 20 35 101))
          (regexp-match? #rx#"E-SafeNet" header)
          (regexp-match? #rx#"LOCK" header))
     (values "esafenet-wrapper" "encrypted-recognized" "heuristic")]
    [(starts-with-bytes? header #"%PDF-")
     (values "pdf-header" "unknown" "measured")]
    [(starts-with-bytes? header (bytes 55 122 188 175 39 28))
     (values "7z-header" "unknown" "measured")]
    [(or (starts-with-bytes? header (bytes 80 75 3 4))
         (starts-with-bytes? header (bytes 80 75 5 6))
         (starts-with-bytes? header (bytes 80 75 7 8)))
     (values "zip-header" "unknown" "measured")]
    [else (values "unknown" "unknown" "measured")]))

;; A dedicated exception lets the CLI report unsafe paths without
;; echoing user-supplied paths or conflating them with missing files.
(struct exn:fail:unsafe-scan-path exn:fail () #:transparent)

(define (reject-linked-path who)
  (raise
   (exn:fail:unsafe-scan-path
    (format "~a: source path contains a filesystem link" who)
    (current-continuation-marks))))

;; A final regular file may still be reached through a linked parent.
;; Inspect every existing path component without resolving the link target.
;; This is a best-effort path check, not an atomic handle-level guarantee.
(define (linked-path-component? source)
  (let loop ([candidate (path->complete-path source)])
    (if (memq (file-or-directory-type candidate #f) '(link directory-link))
        #t
        (let-values ([(parent _name _directory?) (split-path candidate)])
          (and (path? parent) (loop parent))))))

(define (inspect-file source)
  (when (linked-path-component? source)
    (reject-linked-path 'inspect-file))
  (unless (eq? (file-or-directory-type source #f) 'file)
    (error 'inspect-file "source must be an accessible regular file, not a link"))
  ;; Reject links in every path component. This does not close path-swap races.
  ;; Read only. Keep hashing streaming: no file->bytes on large documents.
  (call-with-input-file source
    (lambda (in)
      (define probe (read-bytes 4096 in))
      (define header (if (eof-object? probe) #"" probe))
      (define-values (signature classification evidence)
        (classify-header header))
      (file-position in 0)
      (define digest (bytes->hex-string (sha256-bytes in)))
      (hash 'fileName (path->string (file-name-from-path (path->complete-path source)))
            'sizeBytes (file-size source)
            'sha256 digest
            'signature signature
            'classification classification
            'evidence evidence
            'readView "current-process"))
    #:mode 'binary))

(define (scan-tree source [max-files 1000])
  ;; clean-record projection: identical contract to before resume existed
  (define-values (entries skipped truncated? _reused)
    (scan-tree/resume source max-files #f))
  (values (map (lambda (e) (hash-ref e 'record)) entries)
          skipped
          truncated?))

;; Resume-aware scan (issue #4). prior maps ABSOLUTE path strings to a
;; previous manifest's file entry. A file whose size AND mtime both match
;; the prior entry reuses the recorded sha256/classification without
;; re-reading content; anything else is inspected fresh. Entries are
;; returned as {path mtimeSec record} hashes; path-sorted order is kept.
(define (scan-tree/resume source max-files prior)
  (when (linked-path-component? source)
    (reject-linked-path 'scan-tree))
  (unless (and (exact-integer? max-files) (<= 1 max-files 100000))
    (raise-argument-error 'scan-tree "integer from 1 through 100000" max-files))
  (unless (memq (file-or-directory-type source #f) '(file directory))
    (error 'scan-tree "source must be an accessible regular file or directory, not a link"))
  (define entries (list))
  (define skipped 0)
  (define reused 0)
  (define truncated? #f)
  (define (walk path)
    (unless truncated?
      (with-handlers ([exn:fail? (lambda (_)
                                   (set! skipped (add1 skipped)))])
        (case (file-or-directory-type path #f)
          [(directory)
           (for ([child (in-list (sort (directory-list path)
                                       string<?
                                       #:key path->string))])
             (unless truncated?
               (walk (build-path path child))))]
          [(file)
           (cond [(>= (length entries) max-files)
                  (set! truncated? #t)]
                 [else
                  (define key (path->string (path->complete-path path)))
                  (define prior-entry
                    (and prior (hash-ref prior key #f)))
                  (define size (file-size path))
                  (define mtime (file-or-directory-modify-seconds path #f))
                  (define reuse?
                    (and prior-entry
                         (= size (hash-ref prior-entry 'sizeBytes #f))
                         (= mtime (hash-ref prior-entry 'mtimeSec #f))))
                  (define record
                    (if reuse?
                        ;; reuse: copy every recorded field except the
                        ;; per-artifact path/mtime guards
                        (for/hash ([k (in-hash-keys prior-entry)]
                                   #:unless (member k (list 'path 'mtimeSec)))
                          (values k (hash-ref prior-entry k)))
                        (inspect-file path)))
                  (set! entries
                        (cons (hash 'path key
                                    'mtimeSec mtime
                                    'record record)
                              entries))
                  (when reuse? (set! reused (add1 reused)))])]
          [else (set! skipped (add1 skipped))]))))
  (walk (path->complete-path source))
  (values (reverse entries) skipped truncated? reused))

;; ---------- persistent manifest artifact (.fbmanifest.json) ----------
;;
;; Artifact fields include ABSOLUTE paths and mtimes -- sensitive
;; metadata; per docs/security.md these files live outside the repository
;; in operator-designated locations. The JSON envelope is deliberately
;; unchanged by resume: the artifact carries the reused/refreshed
;; accounting instead.

(define manifest-schema-version 1)

(define (entry->artifact-file e)
  (hash-set (hash-ref e 'record)
            'mtimeSec (hash-ref e 'mtimeSec)))

(define (manifest->jsexpr root entries skipped truncated? max-files reused)
  (hash 'schemaVersion manifest-schema-version
        'kind "fb-manifest"
        'root (path->string (path->complete-path root))
        'maxFiles max-files
        'truncated truncated?
        'skippedCount skipped
        'reusedCount reused
        'files (for/list ([e entries])
                 (hash-set (entry->artifact-file e)
                           'path (hash-ref e 'path)))))

(define (write-manifest! path jsexpr)
  (make-parent-directory* path)
  (with-output-to-file path
    (lambda () (write-json jsexpr) (newline))
    #:exists 'replace)
  path)

(define (read-manifest path)
  (define j (with-input-from-file path read-json))
  (unless (and (hash? j)
               (equal? (hash-ref j 'schemaVersion #f)
                       manifest-schema-version)
               (equal? (hash-ref j 'kind #f) "fb-manifest")
               (list? (hash-ref j 'files #f)))
    (error 'read-manifest "not a FileBoundary manifest artifact: ~a" path))
  j)

;; prior table for scan-tree/resume: ABS path -> artifact file entry
(define (manifest->prior-table j)
  (for/hash ([f (in-list (hash-ref j 'files))])
    (values (hash-ref f 'path) f)))
