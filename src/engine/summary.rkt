#lang racket/base
;; Shared, deliberately conservative UI/CLI-facing summaries.
;; This module has no Rivet or native Windows UI dependency.
(require racket/list
         racket/string
         "inventory.rkt"
         "diagnostics.rkt"
         "recovery.rkt")

(provide scan-summary doctor-summary verify-export-summary scan-statistics)

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
               (not (string=? "" (string-trim path)))
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
  (define registry (hash-ref checks 'registryFilters))
  (define filters
    (for/list ([f (in-list (hash-ref registry 'filters null))])
      (format "~a (altitude ~a)"
              (hash-ref f 'name)
              (string-join
               (hash-ref f 'altitudes null) "/"))))
  (define heuristics (hash-ref checks 'signatureHeuristics))
  (define matched (hash-ref heuristics 'matchedNames null))
  (format (string-append
           "Read-only diagnostics. The driver list below needs no administrator.\n"
           "Registered filter drivers: ~a\n~a\n"
           "Heuristic matches for known encryption/EDR products: ~a\n"
           "Filter Manager runtime listing (needs administrator): filters ~a, instances ~a.\n"
           "~a\n"
           "A name on this list suggests transparent-encryption involvement; it does not prove any file is recoverable.")
          (hash-ref registry 'filterCount 0)
          (if (null? filters)
              "  (none found)"
              (string-join
               (for/list ([f (in-list filters)])
                 (string-append "  " f))
               "\n"))
          (if (null? matched)
              "none"
              (string-join matched ", "))
          (status 'filters)
          (status 'instances)
          (if (hash-ref report 'degraded)
              "Runtime listing incomplete without administrator rights; the registry list above is already complete for what is REGISTERED."
              "Enumeration commands completed; this is not proof of file recovery.")))

;; A presentation-friendly view of the same read-only authorized-export check
;; used by the JSON CLI. Never expose sensitive path names or file contents.
(define (verify-export-summary original-path exported-path)
  (unless (and (string? original-path) (not (string=? "" (string-trim original-path)))
               (string? exported-path) (not (string=? "" (string-trim exported-path))))
    (error 'verify-export-summary "Both local file paths are required"))
  (with-handlers ([exn:fail?
                   (lambda (_)
                     "Authorized export comparison: ERROR. Unable to inspect one or both files. Check local paths and permissions. No files were modified.")])
    (define result (assess-authorized-export original-path exported-path))
    (define bad? (equal? (hash-ref result 'verdict) "failed"))
    (define reasons (hash-ref result 'reasonCodes))
    (format (string-append
             "Authorized export comparison: ~a.\n"
             "Original recognized signature: ~a.\n"
             "Export recognized signature: ~a.\n"
             "Read view identical: ~a.\n"
             "Reason codes: ~a.\n"
             "No decryption performed. No plaintext exported.\n"
             "Independently validate any candidate in an approved reader.")
            (if bad? "FAILED" "UNVERIFIED")
            (hash-ref (hash-ref result 'source) 'signature)
            (hash-ref (hash-ref result 'export) 'signature)
            (if (hash-ref result 'sameReadView) "yes" "no")
            (string-join reasons ", "))))
