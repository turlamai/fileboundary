#lang racket/base

;; Single version source of truth (issue #9, ADR-0008): the `version`
;; field of the rivet project file (rivet.rktd) feeds the CLI `version`
;; output, the release workflow's consistency gate and the release
;; notes. Build metadata `+<short-commit>` comes from the release
;; build's FILEBOUNDARY_BUILD_COMMIT; a plain source tree reports
;; `+dev`.

(require racket/file
         racket/runtime-path
         racket/string)

(provide version product-version)

;; rivet.rktd sits at the repository root, next to src/. Resolved from
;; this file's location, not the current directory, so the CLI works
;; from any invocation directory. cli.rkt is not part of the GUI host
;; distribution closure, so a runtime-path reference is safe here.
(define-runtime-path project-file "../rivet.rktd")

(define version
  (hash-ref (with-input-from-file project-file read) 'version))

(define product-version
  (let ([commit (getenv "FILEBOUNDARY_BUILD_COMMIT")])
    (if (and commit (non-empty-string? commit))
        (string-append version "+" commit)
        (string-append version "+dev"))))
