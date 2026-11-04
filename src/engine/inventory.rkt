#lang racket/base

;; Read-only evidence collection. A recognizable signature is NOT plaintext
;; validation: `plaintext` requires end-to-end structure, and `likely-encrypted`
;; follows the documented semantics table (docs/architecture.md).
(require file/sha1
         json
         racket/file
         racket/list
         racket/path
         racket/set
         racket/string)

(provide inspect-file scan-tree scan-tree/resume classify-header
         entropy-bits sample-tail reject-output-overlap!
         exn:fail:unsafe-scan-path?
         manifest->prior-table manifest->jsexpr write-manifest! read-manifest)

(define (starts-with-bytes? input prefix)
  (and (>= (bytes-length input) (bytes-length prefix))
       (bytes=? (subbytes input 0 (bytes-length prefix)) prefix)))

;; Shannon entropy in bits/byte over concatenated samples, 0.0..8.0.
;; Samples keep this cheap for large files: header (4 KiB) + tail (64 KiB).
(define (entropy-bits . samples)
  (define counts (make-vector 256 0))
  (for ([s (in-list samples)] #:when (bytes? s))
    (for ([b (in-bytes s)])
      (vector-set! counts b (add1 (vector-ref counts b)))))
  (define total (for/sum ([c (in-vector counts)]) c))
  (if (zero? total)
      0.0
      (- (for/sum ([c (in-vector counts)] #:unless (zero? c))
           (let ([p (/ c total)])
             (* p (/ (log p) (log 2.0))))))))

;; last up-to-len bytes of a port
(define (sample-tail in len)
  (define size (file-size (object-name in)))
  (define start (max 0 (- size len)))
  (file-position in start)
  (define tail (read-bytes len in))
  (if (eof-object? tail) #"" tail))

;; Extended classification (issue #4, semantics table in
;; docs/architecture.md): label + evidence class + confidence. A header
;; match alone never yields `plaintext` — end-to-end structure must check
;; out, and container formats whose whole point is compression (7z) get no
;; entropy-based encryption inference at all.
(define (classify-header header
                         #:tail [tail #""]
                         #:entropy [entropy #f])
  (cond
    ;; The first four bytes are stable across the controlled PDF/DOCX pair.
    ;; Bytes 4-7 vary between specimens; require both ASCII markers as well.
    [(and (starts-with-bytes? header (bytes 98 20 35 101))
          (regexp-match? #rx#"E-SafeNet" header)
          (regexp-match? #rx#"LOCK" header))
     (values "esafenet-wrapper" "encrypted-recognized" "heuristic" "high")]
    ;; zip-family: header AND end-of-central-directory = end-to-end structure
    [(or (starts-with-bytes? header (bytes 80 75 3 4))
         (starts-with-bytes? header (bytes 80 75 5 6))
         (starts-with-bytes? header (bytes 80 75 7 8)))
     (cond
       [(let search ([i (- (bytes-length tail) 4)])
          (and (>= i 0)
               (or (bytes=? (subbytes tail i (+ i 4)) (bytes 80 75 5 6))
                   (search (sub1 i)))))
        (values "zip-ooxml" "plaintext" "measured" "high")]
       [else
        ;; header claims a container but the directory is missing: the
        ;; structural inconsistency is itself the evidence
        (values "zip-header" "likely-encrypted" "measured" "medium")])]
    [(starts-with-bytes? header #"%PDF-")
     (cond
       [(regexp-match? #rx#"%%EOF" tail)
        (values "pdf" "plaintext" "measured" "high")]
       [else
        (values "pdf-header" "likely-encrypted" "measured" "medium")])]
    [(starts-with-bytes? header (bytes 55 122 188 175 39 28))
     ;; a 7z file is compressed by design: high entropy proves nothing here
     (values "7z-header" "unknown" "measured" "low")]
    [(and entropy (>= entropy 7.5))
     (values "high-entropy" "likely-encrypted" "measured" "medium")]
    [else (values "unknown" "unknown" "measured" "low")]))

;; A dedicated exception lets the CLI report unsafe paths without
;; echoing user-supplied paths or conflating them with missing files.
;; Also used for destination-overlap refusals (issue #10): a report or
;; manifest must never be written inside the scanned tree.
(struct exn:fail:unsafe-scan-path exn:fail () #:transparent)

(define (reject-linked-path who)
  (raise
   (exn:fail:unsafe-scan-path
    (format "~a: source path contains a filesystem link" who)
    (current-continuation-marks))))

(define (reject-output-overlap who)
  (raise
   (exn:fail:unsafe-scan-path
    (format "~a: the output location overlaps the scanned tree" who)
    (current-continuation-marks))))

;; Is `candidate` equal to or inside `root`? Windows path prefixes compare
;; case-insensitively (the stdlib has no path-has-prefix?, so normalize
;; separators and case here); Unix stays case-sensitive.
(define (path-inside-root? candidate root)
  (define (norm p)
    (define s (string-replace (path->string (path->complete-path p)) "\\" "/"))
    (if (eq? (system-type 'os) 'windows)
        (string-downcase s)
        s))
  (define c (norm candidate))
  (define r (norm root))
  (define r-sep (if (string-suffix? r "/") r (string-append r "/")))
  (or (string=? c r) (string-prefix? c r-sep)))

;; Refuse an artifact destination inside the scanned root (issue #10).
(define (reject-output-overlap! root out)
  (when (path-inside-root? out root)
    (reject-output-overlap 'reject-output-overlap!))
  out)

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
      (file-position in 0)
      (define digest (bytes->hex-string (sha256-bytes in)))
      (define tail (sample-tail in 65536))
      (define entropy
        (entropy-bits (subbytes header 0 (min 4096 (bytes-length header))) tail))
      (define-values (signature classification evidence confidence)
        (classify-header header
                         #:tail tail
                         #:entropy entropy))
      (hash 'fileName (path->string (file-name-from-path (path->complete-path source)))
            'sizeBytes (file-size source)
            'sha256 digest
            'signature signature
            'classification classification
            'evidence evidence
            'confidence confidence
            'entropyBits (real->decimal-string (exact->inexact entropy) 3)
            'readView "current-process"))
    #:mode 'binary))

(define (scan-tree source [max-files 1000]
                   #:exclude-dirs [exclude-dirs '()]
                   #:exclude-exts [exclude-exts '()])
  ;; clean-record projection: identical contract to before resume existed
  (define-values (entries skipped truncated? _reused _excluded)
    (scan-tree/resume source max-files #f
                      #:exclude-dirs exclude-dirs
                      #:exclude-exts exclude-exts))
  (values (map (lambda (e) (hash-ref e 'record)) entries)
          skipped
          truncated?))

;; Resume-aware scan (issue #4). prior maps ABSOLUTE path strings to a
;; previous manifest's file entry. A file whose size AND mtime both match
;; the prior entry reuses the recorded sha256/classification without
;; re-reading content; anything else is inspected fresh. Entries are
;; returned as {path mtimeSec record} hashes; path-sorted order is kept.
;; Exclude lists (issue #4): absolute directory prefixes whose whole
;; subtree is skipped, and file extensions skipped at the leaf — both are
;; counted and reported in the manifest so the gaps stay explainable.
(define (scan-tree/resume source max-files prior
                          #:exclude-dirs [exclude-dirs '()]
                          #:exclude-exts [exclude-exts '()])
  (when (linked-path-component? source)
    (reject-linked-path 'scan-tree))
  (unless (and (exact-integer? max-files) (<= 1 max-files 100000))
    (raise-argument-error 'scan-tree "integer from 1 through 100000" max-files))
  (unless (memq (file-or-directory-type source #f) '(file directory))
    (error 'scan-tree "source must be an accessible regular file or directory, not a link"))
  (define excluded-dirs
    (for/set ([d (in-list exclude-dirs)])
      (path->complete-path d)))
  (define excluded-exts
    (for/set ([e (in-list exclude-exts)])
      (string-downcase e)))
  (define entries (list))
  (define skipped 0)
  (define excluded-count 0)
  (define reused 0)
  (define truncated? #f)
  (define (dir-excluded? path)
    (for/or ([d (in-set excluded-dirs)])
      (path-inside-root? path d)))
  (define (ext-excluded? path)
    (define ext (filename-extension path))
    (and ext
         (set-member? excluded-exts
                      (string-downcase
                       (string-append "." (bytes->string/utf-8 ext))))))
  (define (walk path)
    (unless truncated?
      (with-handlers ([exn:fail? (lambda (_)
                                   (set! skipped (add1 skipped)))])
        (case (file-or-directory-type path #f)
          [(directory)
           (cond
             [(dir-excluded? path)
              (set! excluded-count (add1 excluded-count))]
             [else
              (for ([child (in-list (sort (directory-list path)
                                          string<?
                                          #:key path->string))])
                (unless truncated?
                  (walk (build-path path child))))])]
          [(file)
           (cond [(>= (length entries) max-files)
                  (set! truncated? #t)]
                 [(ext-excluded? path)
                  (set! excluded-count (add1 excluded-count))]
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
  (values (reverse entries) skipped truncated? reused excluded-count))

;; ---------- persistent manifest artifact (.fbmanifest.json) ----------
;;
;; Artifact fields include ABSOLUTE paths and mtimes -- sensitive
;; metadata; per docs/security.md these files live outside the repository
;; in operator-designated locations, and never inside the scanned tree
;; (reject-output-overlap!, issue #10). The JSON envelope is deliberately
;; unchanged by resume: the artifact carries the reused/refreshed
;; accounting plus the applied exclusion filters instead.

(define manifest-schema-version 1)

(define (entry->artifact-file e)
  (hash-set (hash-ref e 'record)
            'mtimeSec (hash-ref e 'mtimeSec)))

(define (manifest->jsexpr root entries skipped truncated? max-files reused
                          [excluded-count 0]
                          [exclude-dirs '()]
                          [exclude-exts '()])
  (hash 'schemaVersion manifest-schema-version
        'kind "fb-manifest"
        'root (path->string (path->complete-path root))
        'maxFiles max-files
        'truncated truncated?
        'skippedCount skipped
        'reusedCount reused
        'excludedCount excluded-count
        'appliedExcludeDirs (map path->string (map path->complete-path exclude-dirs))
        'appliedExcludeExts exclude-exts
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
