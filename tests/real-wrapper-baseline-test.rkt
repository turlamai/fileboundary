#lang racket/base

;; Approved controlled encrypted DOCX twin (ADR-0004). Do not log content.
(require json
         rackunit
         racket/runtime-path
         racket/list
         "../src/engine/inventory.rkt")

(define-runtime-path fixtures "fixtures/real-samples")
(define baseline
  (call-with-input-file (build-path fixtures "baseline.json") read-json))
(check-equal? (hash-ref baseline 'exception) "ADR-0004")
(define encrypted-meta (first (hash-ref baseline 'specimens)))
(define specimen (build-path fixtures (hash-ref encrypted-meta 'file)))
(check-true (file-exists? specimen))
(define report (inspect-file specimen))
(check-equal? (hash-ref report 'sizeBytes) (hash-ref encrypted-meta 'sizeBytes))
(check-equal? (hash-ref report 'sha256) (hash-ref encrypted-meta 'sha256))
(check-equal? (hash-ref report 'classification)
              (hash-ref encrypted-meta 'expectedClassification))
(check-not-equal? (hash-ref report 'classification) "plaintext")
(check-equal? (hash-ref report 'signature) "esafenet-wrapper")
(check-equal? (hash-ref report 'evidence) "heuristic")
(check-equal? (hash-ref report 'readView) "current-process")
(check-false (hash-has-key? report 'contents))
(check-false (hash-has-key? report 'plaintext))
