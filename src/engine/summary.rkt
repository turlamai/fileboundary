#lang racket/base
;; Shared, deliberately conservative UI/CLI-facing summaries.
;; This module has no Rivet or native Windows UI dependency.
(require racket/list
         "inventory.rkt"
         "diagnostics.rkt")

(provide scan-summary doctor-summary scan-statistics)

(define (scan-statistics records)
  (define recognized
    (count (lambda (record)
             (equal? (hash-ref record 'classification) "encrypted-recognized"))
           records))
  (hash 'total (length records)
        'recognizedWrapper recognized
        'other (- (length records) recognized)))

(define (scan-summary path #:max-files [max-files 200])
  (unless (and (string? path)
               (not (regexp-match? #px"^\\s*$" path))
               (<= (string-length path) 32767))
    (raise-argument-error 'scan-summary "nonempty path string with at most 32767 characters" path))
  (define-values (files skipped truncated?) (scan-tree path max-files))
  (define stats (scan-statistics files))
  (format (string-append
           "Read-only scan of this process's file view.\n"
           "Inspected: ~a file(s).\n"
           "Known encryption-wrapper signatures: ~a.\n"
           "Other or inconclusive signatures: ~a.\n"
           "Skipped entries: ~a. Limit reached: ~a.\n"
           "Signatures do not prove plaintext or successful decryption.")
          (hash-ref stats 'total)
          (hash-ref stats 'recognizedWrapper)
          (hash-ref stats 'other)
          skipped
          (if truncated? "yes" "no")))

(define (doctor-summary)
  (define report (doctor-report))
  (define checks (hash-ref report 'checks))
  (define (status name)
    (hash-ref (hash-ref checks name) 'status))
  (format (string-append
           "Read-only Windows Filter Manager diagnostics.\n"
           "Filters: ~a. Instances: ~a.\n"
           "~a\n"
           "A failed or denied check is not evidence that no filters exist.")
          (status 'filters)
          (status 'instances)
          (if (hash-ref report 'degraded)
              "Results incomplete; check privileges and local diagnostic tools."
              "Enumeration commands completed; this is not proof of file recovery.")))
