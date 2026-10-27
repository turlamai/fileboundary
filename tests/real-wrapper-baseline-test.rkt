#lang racket/base

;; Repository owner explicitly approved this one encrypted fixture in ADR-0003.
;; Never dump file bytes, document contents or full local paths in CI.
(require json
         rackunit
         racket/path
         racket/runtime-path
         "../src/engine/inventory.rkt")

(define-runtime-path fixtures "fixtures/real-samples")
(define meta
  (call-with-input-file (build-path fixtures "baseline.json") read-json))
(define specimen (build-path fixtures (hash-ref meta 'file)))

(check-equal? (hash-ref meta 'exception) "ADR-0003")
(check-true (file-exists? specimen))

;; The SHA-256 checks both fixture provenance and whether checkout changed bytes.
(define report (inspect-file specimen))
(check-equal? (hash-ref report 'sizeBytes) (hash-ref meta 'sizeBytes))
(check-equal? (hash-ref report 'sha256) (hash-ref meta 'sha256))
(check-equal? (hash-ref report 'classification)
              (hash-ref meta 'expectedClassification))
(check-not-equal? (hash-ref report 'classification) "plaintext")
(check-equal? (hash-ref report 'signature) "esafenet-wrapper")
(check-equal? (hash-ref report 'evidence) "heuristic")
(check-equal? (hash-ref report 'readView) "current-process")
(check-false (hash-has-key? report 'contents))
(check-false (hash-has-key? report 'plaintext))
