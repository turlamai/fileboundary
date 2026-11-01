#lang racket/base

;; Persistent manifest artifact + resume tests (issue #4): fresh scan
;; writes .fbmanifest.json; resume reuses unchanged entries (guard =
;; size+mtime), refreshes changed ones, drops deleted ones, adds new
;; ones. Envelope shape stays unchanged by resume.

(require rackunit
         json
         racket/file
         racket/port
         racket/path
         racket/runtime-path
         "../src/cli.rkt"
         "../src/engine/inventory.rkt")

(define (invoke args)
  (define stdout (open-output-string))
  (define code (parameterize ([current-output-port stdout])
                 (run-cli args)))
  (values code (string->jsexpr (get-output-string stdout))))

;; ---------- fixture tree ----------

(define root (make-temporary-file "fb-man~a" 'directory))
(define (put rel content)
  (define p (build-path root rel))
  (make-directory* (path-only p))
  (display-to-file content p #:exists 'replace))

(put "a.txt" "alpha")
(put "b.txt" "bravo")
(make-directory* (build-path root "sub"))
(put "sub/c.txt" "charlie")

;; ---------- fresh scan with --manifest-out ----------

(define m1 (make-temporary-file "fb-m1~a.json"))
(define-values (sc1 d1)
  (invoke (list "scan" (path->string root)
                "--max-files" "100"
                "--manifest-out" (path->string m1))))
(check-equal? sc1 0)
(check-true (hash? (hash-ref d1 'data #f)) (format "d1 envelope: ~a" d1))
(check-equal? (hash-ref (hash-ref d1 'data) 'count) 3)

(define art (with-input-from-file m1 read-json))
(check-equal? (hash-ref art 'kind) "fb-manifest")
(check-equal? (hash-ref art 'schemaVersion) 1)
(check-equal? (hash-ref art 'reusedCount) 0)
(check-equal? (length (hash-ref art 'files)) 3)
;; artifact entries carry absolute path + mtime guard + the record fields
(define a1
  (for/first ([f (hash-ref art 'files)]
              #:when (equal? (hash-ref f 'fileName) "a.txt"))
    f))
(check-true (and a1 #t))
(check-true (hash-has-key? a1 'path))
(check-true (hash-has-key? a1 'mtimeSec))
(check-true (hash-has-key? a1 'sha256))

;; ---------- evolve the tree, then resume ----------

;; change b.txt (re-hash), add d.txt (add), delete c.txt (drop)
(put "b.txt" "BRAVO-v2")
(put "sub/d.txt" "delta")
(delete-file (build-path root "sub" "c.txt"))

(define m2 (make-temporary-file "fb-m2~a.json"))
(define-values (sc2 d2)
  (invoke (list "scan" (path->string root)
                "--resume" (path->string m1)
                "--manifest-out" (path->string m2))))
(displayln (format "DBG sc2=~a m2size=~a" sc2 (file-size m2)))
(check-equal? sc2 0)
(check-equal? (hash-ref (hash-ref d2 'data) 'count) 3)

(define art2 (with-input-from-file m2 read-json))
(check-equal? (hash-ref art2 'reusedCount) 1) ; only a.txt unchanged
(check-equal? (length (hash-ref art2 'files)) 3)

;; a.txt reused: same sha256 as before
(define a2
  (for/first ([f (hash-ref art2 'files)]
              #:when (equal? (hash-ref f 'fileName) "a.txt"))
    f))
(check-equal? (hash-ref a2 'sha256) (hash-ref a1 'sha256))
;; b.txt refreshed: new content hash present
(define b2
  (for/first ([f (hash-ref art2 'files)]
              #:when (equal? (hash-ref f 'fileName) "b.txt"))
    f))
(check-false (equal? (hash-ref b2 'sha256)
                     (for/first ([f (hash-ref art 'files)]
                                 #:when (equal? (hash-ref f 'fileName) "b.txt"))
                       (hash-ref f 'sha256))))
;; deleted c.txt gone; added d.txt present
(check-false (for/or ([f (hash-ref art2 'files)])
               (equal? (hash-ref f 'fileName) "c.txt")))
(check-true (for/or ([f (hash-ref art2 'files)])
              (equal? (hash-ref f 'fileName) "d.txt")))

;; ---------- guard: drifting base refuses nothing silently ----------

;; resume must also work when nothing changed: reused = all
(define-values (sc3 d3)
  (invoke (list "scan" (path->string root)
                "--resume" (path->string m2)
                "--manifest-out" (path->string m2))))
(check-equal? sc3 0)
(define art3 (with-input-from-file m2 read-json))
(check-equal? (hash-ref art3 'reusedCount) 3)

;; invalid artifact errors out (exit 3 runtime, sanitized)
(define bad-man (make-temporary-file "fb-bad~a.json"))
(displayln "{not json" (open-output-file bad-man #:exists 'replace))
(define-values (sc4 d4)
  (invoke (list "scan" (path->string root)
                "--resume" (path->string bad-man))))
(check-equal? sc4 3)
(check-equal? (hash-ref d4 'status) "error")

;; envelope shape unchanged vs a plain scan
(define-values (sc5 d5) (invoke (list "scan" (path->string root))))
(check-equal? (hash-ref (hash-ref d5 'data) 'count) 3)
(check-false (hash-has-key? d5 'reusedCount))
