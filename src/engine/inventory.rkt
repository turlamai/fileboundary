#lang racket/base

;; Read-only evidence collection. A recognizable signature is NOT plaintext validation.
(require file/sha1
         racket/file
         racket/list
         racket/path)

(provide inspect-file scan-tree classify-header)

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
    (error 'inspect-file "source path contains a filesystem link"))
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
  (when (linked-path-component? source)
    (error 'scan-tree "source path contains a filesystem link"))
  (unless (and (exact-integer? max-files) (<= 1 max-files 100000))
    (raise-argument-error 'scan-tree "integer from 1 through 100000" max-files))
  (unless (memq (file-or-directory-type source #f) '(file directory))
    (error 'scan-tree "source must be an accessible regular file or directory, not a link"))
  ;; Link-aware type checks keep leaf symlinks and linked directories out.
  ;; Windows non-symlink reparse points require a separate OS-level check.
  (define records '())
  (define skipped 0)
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
           (if (>= (length records) max-files)
               (set! truncated? #t)
               (set! records (cons (inspect-file path) records)))]
          [else (set! skipped (add1 skipped))]))))
  (walk (path->complete-path source))
  (values (reverse records) skipped truncated?))
