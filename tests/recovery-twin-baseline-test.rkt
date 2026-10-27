#lang racket/base

;; Controlled, owner-approved twin-pair baseline from ADR-0004.
;; No document contents are logged, copied, or embedded in test output.
(require rackunit
         json
         racket/runtime-path
         "../src/engine/inventory.rkt"
         "../src/engine/recovery.rkt")

(define-runtime-path fixture-root "fixtures/real-samples")
(define baseline
  (call-with-input-file (build-path fixture-root "baseline-twins.json")
    read-json))
(check-equal? (hash-ref baseline 'exception) "ADR-0004")
(define specimens (hash-ref baseline 'specimens))
(check-equal? (length specimens) 2)

(define encrypted-meta (first specimens))
(define plain-meta (second specimens))
(define encrypted-path (build-path fixture-root (hash-ref encrypted-meta 'file)))
(define plain-path (build-path fixture-root (hash-ref plain-meta 'file)))
(define encrypted (inspect-file encrypted-path))
(define plaintext (inspect-file plain-path))

(check-equal? (hash-ref encrypted 'sizeBytes) (hash-ref encrypted-meta 'sizeBytes))
(check-equal? (hash-ref plaintext 'sizeBytes) (hash-ref plain-meta 'sizeBytes))
(check-equal? (hash-ref encrypted 'sha256) (hash-ref encrypted-meta 'sha256))
(check-equal? (hash-ref plaintext 'sha256) (hash-ref plain-meta 'sha256))
(check-equal? (hash-ref encrypted 'classification) "encrypted-recognized")
(check-equal? (hash-ref encrypted 'signature) "esafenet-wrapper")
(check-equal? (hash-ref plaintext 'signature) "zip-header")
(check-not-equal? (hash-ref plaintext 'classification) "encrypted-recognized")

;; Ground-truth, *already plaintext* twin is a verification reference, not
;; a recovered output produced by this program. Structural/open checks remain.
(define result
  (assess-authorized-export encrypted-path
                            plain-path
                            (hash-ref plain-meta 'sha256)))
(check-equal? (hash-ref result 'trustedPlaintextSha256Comparison) "matched")
(check-equal? (hash-ref result 'verdict) "unverified")
(check-equal? (hash-ref result 'fullFormatValidation) "notPerformed")
(check-equal? (hash-ref result 'independentReader) "notTested")
(check-false (hash-ref result 'plaintextBytesExported))
