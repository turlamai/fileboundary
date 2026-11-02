#lang racket/base

;; Assess only an operator-supplied export from an authorized decryption path.
;; This module NEVER decrypts data, creates plaintext, or writes to either input.
(require racket/file
         racket/path
         racket/string
         "inventory.rkt")

(provide assess-authorized-export valid-sha256?)

(define (valid-sha256? text)
  (and (string? text)
       (regexp-match? #px"^[0-9a-fA-F]{64}$" text)))

(define (pdf-tail-hints path)
  (call-with-input-file path
    (lambda (in)
      (define end (file-size path))
      (file-position in (max 0 (- end 4096)))
      (define read-result (read-bytes 4096 in))
      (define tail (if (eof-object? read-result) #"" read-result))
      (hash 'eofMarkerSeen (and (regexp-match? #rx#"%%EOF" tail) #t)
            'xrefMarkerSeen (and (regexp-match? #rx#"startxref" tail) #t)
            'evidence "heuristic"))
    #:mode 'binary))

(define (assess-authorized-export original-path exported-path
                                  [trusted-plaintext-sha256 #f])
  (when (and trusted-plaintext-sha256
             (not (valid-sha256? trusted-plaintext-sha256)))
    (raise-argument-error 'assess-authorized-export
                          "64-character hexadecimal plaintext SHA-256"
                          trusted-plaintext-sha256))
  ;; inspect-file excludes directory/symlink inputs and hashes streaming.
  (define original (inspect-file original-path))
  (define exported (inspect-file exported-path))
  (define unchanged-view?
    (string=? (hash-ref original 'sha256)
              (hash-ref exported 'sha256)))
  (define still-wrapped?
    (equal? (hash-ref exported 'signature) "esafenet-wrapper"))
  (define trusted-result
    (cond
      [(not trusted-plaintext-sha256) "notProvided"]
      [(string-ci=? (hash-ref exported 'sha256) trusted-plaintext-sha256)
       "matched"]
      [else "mismatched"]))
  (define signature (hash-ref exported 'signature))
  (define pdf?
    (equal? signature "pdf-header"))
  (define pdf-hints
    (if pdf?
        (pdf-tail-hints exported-path)
        (hash 'eofMarkerSeen #f
              'xrefMarkerSeen #f
              'evidence "notApplicable")))
  ;; These observations are NOT a full PDF parser nor an independent reader.
  ;; Even a matched trusted baseline is recorded but does not automatically
  ;; satisfy the repository's independent open/structural verification gates.
  (define failure?
    (or still-wrapped? (equal? trusted-result "mismatched")))
  (define reasons
    (append
     (if still-wrapped? (list "exportStillEncryptedWrapper") '())
     (if (equal? trusted-result "mismatched")
         (list "trustedPlaintextHashMismatch") '())
     (if unchanged-view?
         (list "identicalReadView") '())
     (if (not pdf?) (list "notIdentifiedAsPdf") '())
     (if (and pdf?
              (not (and (hash-ref pdf-hints 'eofMarkerSeen)
                        (hash-ref pdf-hints 'xrefMarkerSeen))))
         (list "incompletePdfStructureHints") '())
     (if (not (equal? (hash-ref original 'classification)
                      "encrypted-recognized"))
         (list "originalWrapperNotRecognized") '())
     (list "independentReaderAndFullStructuralValidationPending")))
  (hash 'verdict (if failure? "failed" "unverified")
        'source (hash 'fileName (hash-ref original 'fileName)
                      'sha256 (hash-ref original 'sha256)
                      'sizeBytes (hash-ref original 'sizeBytes)
                      'signature (hash-ref original 'signature)
                      'classification (hash-ref original 'classification))
        'export (hash 'fileName (hash-ref exported 'fileName)
                      'sha256 (hash-ref exported 'sha256)
                      'sizeBytes (hash-ref exported 'sizeBytes)
                      'signature signature
                      'classification (hash-ref exported 'classification))
        'sameReadView unchanged-view?
        'trustedPlaintextSha256Comparison trusted-result
        'pdfStructureHints pdf-hints
        'fullFormatValidation "notPerformed"
        'independentReader "notTested"
        'evidence "measured-and-heuristic"
        'authorizedExport "operatorProvided"
        'reasonCodes reasons
        'readView "current-process"
        'plaintextBytesExported #f))
