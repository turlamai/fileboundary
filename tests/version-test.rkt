#lang racket/base

;; Version source-of-truth tests (issue #9): the CLI reports the
;; rivet.rktd project version, with build metadata from
;; FILEBOUNDARY_BUILD_COMMIT (+dev in a plain source tree).

(require rackunit
         racket/file
         racket/string
         "../src/version.rkt")

(define cfg (with-input-from-file "../rivet.rktd" read))

(check-equal? version (hash-ref cfg 'version))
(check-true (string-prefix? product-version version))

;; a plain source tree (no release stamp) reports +dev
(unless (getenv "FILEBOUNDARY_BUILD_COMMIT")
  (check-equal? product-version (string-append version "+dev")))
