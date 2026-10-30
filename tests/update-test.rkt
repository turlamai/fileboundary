#lang racket/base

;; Update engine tests (ADR-0008): SHA-256 vectors, version compare,
;; manifest parsing, check logic, and full/delta package application with
;; locally built packages — no network anywhere.

(require rackunit
         json
         racket/file
         racket/path
         file/zip
         "../src/engine/sha256.rkt"
         "../src/engine/update.rkt")

;; ---------- SHA-256 (FIPS 180-4 vectors) ----------

(check-equal? (sha256-hex #"")
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
(check-equal? (sha256-hex #"abc")
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
(check-equal? (sha256-hex #"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

;; file hashing agrees with byte hashing
(define tmp0 (make-temporary-file "fb-sha~a.txt"))
(displayln "hello sha" (open-output-file tmp0 #:exists 'replace))
(check-equal? (sha256-file tmp0) (sha256-hex (file->bytes tmp0)))
(delete-file tmp0)

;; ---------- versions ----------

(check-equal? (call-with-values (lambda () (parse-version "0.2.0+abc123")) list)
              (list (list 0 2 0) "abc123"))
(check-equal? (call-with-values (lambda () (parse-version "1.0.0")) list)
              (list (list 1 0 0) #f))
(check-equal? (version<? "0.1.0" "0.2.0") #t)
(check-equal? (version<? "0.10.0" "0.2.0") #f)
(check-equal? (version<? "0.1.9" "0.1.10") #t)
(check-equal? (version=? "1.2.3+x" "1.2.3+y") #t)
(check-exn exn:fail? (lambda () (parse-version "0.1.0-dev")))

;; ---------- manifest ----------

(define valid-manifest
  (hash 'schemaVersion 1
        'channel "stable"
        'version "0.3.0"
        'commit "abc1234"
        'created "2026-10-30T00:00:00Z"
        'package (hash 'kind "full" 'name "FB.zip" 'bytes 123
                       'sha256 (make-string 64 #\a)
                       'url "https://example.invalid/FB.zip")
        'deltas '()))

(check-equal? (parse-manifest valid-manifest) valid-manifest)
(check-exn exn:fail? (lambda () (parse-manifest (hash-remove valid-manifest 'deltas))))
(check-exn exn:fail? (lambda () (parse-manifest
                                 (hash-set valid-manifest 'version "0.1.0-dev"))))
(check-exn exn:fail? (lambda () (parse-manifest
                                 (hash-set valid-manifest 'package
                                           (hash-remove (hash-ref valid-manifest 'package) 'sha256)))))

;; ---------- check ----------

(define check-result (check-update valid-manifest "0.1.0"))
(check-equal? (hash-ref check-result 'action) "update")
(check-equal? (hash-ref check-result 'latestVersion) "0.3.0")
(check-equal? (hash-ref (check-update valid-manifest "0.3.0") 'action) "none")

;; ---------- package builders ----------

;; write a file tree from an assoc of rel-path (forward slashes) -> bytes
(define (make-tree root files)
  (for ([(rel content) files])
    (define p (build-path root (string->path rel)))
    (make-directory* (path-only p))
    (with-output-to-file p (lambda () (write-bytes content)) #:exists 'replace)))

;; sha256 of a string, as hex
(define (h s) (sha256-hex (string->bytes/utf-8 s)))

(define (zip-tree zip-path src-dir)
  ;; file/zip stores paths as given: run from inside the tree so entries
  ;; are relative, never absolute
  (when (file-exists? zip-path) (delete-file zip-path))
  (parameterize ([current-directory src-dir])
    (zip zip-path (string->path "."))))

;; ---------- full package apply ----------

(define pkg-src (make-temporary-file "fb-pkg-src~a" 'directory))
(make-tree pkg-src
           (hash "app.txt" #"new app"
                 "bin/tool.txt" #"new tool"))
(define filetable
  (hash 'version "0.3.0"
        'files (list (hash 'path "app.txt" 'sha256 (h "new app"))
                     (hash 'path "bin/tool.txt" 'sha256 (h "new tool")))))
(with-output-to-file (build-path pkg-src "filetable.json")
  (lambda () (write-json filetable)) #:exists 'replace)
(define pkg-zip (make-temporary-file "fb-full~a.zip"))
(zip-tree pkg-zip pkg-src)

(define pkg-meta (hash 'kind "full"
                       'sha256 (sha256-file pkg-zip)))

(define root (make-temporary-file "fb-root~a" 'directory))
(check-equal? (apply-package pkg-zip pkg-meta root) "0.3.0")
(check-equal? (installed-version root) "0.3.0")
(check-equal? (file->string (build-path root "releases" "0.3.0" "app.txt"))
              "new app")
(check-equal? (file->string (build-path root "releases" "0.3.0" "bin" "tool.txt"))
              "new tool")

;; tampered package must be rejected before extraction
(define tampered (make-temporary-file "fb-tampered~a.zip"))
(copy-file pkg-zip tampered #:exists-ok? #t)
;; corrupt: flip bytes late in the file (past headers, inside payload)
(define raw (file->bytes tampered))
(define raw2 (bytes-copy raw))
(bytes-set! raw2 (- (bytes-length raw2) 3)
            (bitwise-xor (bytes-ref raw2 (- (bytes-length raw2) 3)) #xFF))
(display-to-file raw2 tampered #:exists 'replace)
(check-exn exn:fail? (lambda () (apply-package tampered pkg-meta root)))
(delete-file tampered)

;; ---------- delta package apply ----------

;; base install at 0.1.0 with one file whose guard we replace, one we delete
(define root2 (make-temporary-file "fb-root2~a" 'directory))
(make-tree root2 (hash "app.txt" #"old app"
                       "bin/obsolete.txt" #"obsolete"))
(set-current-version! root2 "0.1.0")

(define delta-src (make-temporary-file "fb-delta-src~a" 'directory))
(make-tree delta-src
           (hash "payload/app.txt" #"patched app"
                 "payload/bin/added.txt" #"added"))
(define delta-spec
  (hash 'schemaVersion 1
        'baseVersion "0.1.0"
        'targetVersion "0.2.0"
        'operations (list (hash 'action "replace" 'path "app.txt"
                                'baseSha256 (h "old app")
                                'sha256 (h "patched app"))
                          (hash 'action "add" 'path "bin/added.txt"
                                'sha256 (h "added"))
                          (hash 'action "delete" 'path "bin/obsolete.txt"
                                'baseSha256 (h "obsolete")))))
(with-output-to-file (build-path delta-src "delta.json")
  (lambda () (write-json delta-spec)) #:exists 'replace)
(define delta-zip (make-temporary-file "fb-delta~a.zip"))
(zip-tree delta-zip delta-src)

(define delta-meta
  (hash 'kind "delta" 'sha256 (sha256-file delta-zip)))

(check-equal? (apply-package delta-zip delta-meta root2) "0.2.0")
(check-equal? (installed-version root2) "0.2.0")
(check-equal? (file->string (build-path root2 "app.txt")) "patched app")
(check-equal? (file->string (build-path root2 "bin" "added.txt")) "added")
(check-false (file-exists? (build-path root2 "bin" "obsolete.txt")))

;; guard mismatch (drifted base) must abort the delta
(define root3 (make-temporary-file "fb-root3~a" 'directory))
(make-tree root3 (hash "app.txt" #"DRIFTED content"))
(set-current-version! root3 "0.1.0")
(check-exn exn:fail? (lambda () (apply-package delta-zip delta-meta root3)))
;; aborted delta must not have touched the tree
(check-equal? (file->string (build-path root3 "app.txt")) "DRIFTED content")
(check-equal? (installed-version root3) "0.1.0")

;; ---------- CLI envelope smoke ----------

(require "../src/cli.rkt"
         racket/port)
(define (invoke args)
  (define stdout (open-output-string))
  (define code (parameterize ([current-output-port stdout])
                 (run-cli args)))
  (values code (string->jsexpr (get-output-string stdout))))

(define-values (sc1 d1) (invoke '("update" "status")))
(check-equal? sc1 0)
(check-equal? (hash-ref d1 'errors) '())
(define d1-data (hash-ref d1 'data))
(check-equal? (hash-ref d1-data 'runningVersion) "0.2.0+dev")
(check-true (hash-has-key? d1-data 'installRoot))

(define manifest-path (make-temporary-file "fb-manifest~a.json"))
(with-output-to-file manifest-path
  (lambda () (write-json valid-manifest)) #:exists 'replace)
(define-values (sc2 d2)
  (invoke (list "update" "check" "--manifest" (path->string manifest-path))))
(check-equal? sc2 0)
(check-equal? (hash-ref d2 'errors) '())
(define d2-data (hash-ref d2 'data))
(check-equal? (hash-ref d2-data 'updateAvailable) #t)
(check-equal? (hash-ref d2-data 'latestVersion) "0.3.0")
