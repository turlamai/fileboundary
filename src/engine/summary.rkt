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

;; Operator-facing text for the Diagnostics panel. Leads with the
;; encryption-class filters (service Group = FSFilter Encryption, the
;; authoritative class signal), then the full registered inventory, then
;; the name heuristics. An incomplete registry listing says so on its own
;; line - a truncated listing once read "19 registered filters" with the
;; encryption filter in the dropped half of the alphabet.
(define (doctor-summary [report (doctor-report)])
  (define checks (hash-ref report 'checks))
  (define (status name)
    (hash-ref (hash-ref checks name 'hash) 'status "missing"))
  (define registry (hash-ref checks 'registryFilters (hash)))
  (define rows (hash-ref registry 'filters '()))
  (define registry-ok? (equal? (hash-ref registry 'status #f) "ok"))
  (define (render f)
    (format "  ~a (altitude ~a~a~a)~a"
            (hash-ref f 'name)
            (string-join (hash-ref f 'altitudes '("?")) "/")
            (if (hash-ref f 'group #f) (format ", group ~a" (hash-ref f 'group)) "")
            (if (hash-ref f 'start #f) (format ", start ~a" (hash-ref f 'start)) "")
            (if (member (hash-ref f 'name) '("FileCrypt" "aksdf")) " - Windows inbox" "")))
  (define encryption-names (encryption-group-filters rows))
  (define encryption-rows
    (filter (lambda (f) (member (hash-ref f 'name) encryption-names)) rows))
  (define heuristics (hash-ref checks 'signatureHeuristics (hash)))
  (define matched (hash-ref heuristics 'matchedNames '()))
  (define fltmc-line
    (format "Filter Manager runtime view (needs administrator): filters ~a, instances ~a."
            (status 'filters) (status 'instances)))
  (format (string-append
           "Read-only diagnostics: enumeration only. Nothing here proves that any file is recoverable.\n"
           "Encryption-group filter drivers (Group = FSFilter Encryption): ~a\n~a\n"
           "Registered filter drivers: ~a\n~a\n"
           "Heuristic name matches (suggestive only): ~a\n"
           "~a\n"
           "~a")
          (length encryption-rows)
          (if (null? encryption-rows) "  (none found)" (string-join (map render encryption-rows) "\n"))
          (if registry-ok?
              (format "~a" (hash-ref registry 'filterCount (length rows)))
              (format "~a shown of an INCOMPLETE listing (registry query status: ~a)"
                      (length rows) (hash-ref registry 'status)))
          (if (null? rows)
              "  (none found)"
              (string-join (map render rows) "\n"))
          (if (null? matched) "none" (string-join matched ", "))
          fltmc-line
          (cond
            [(not registry-ok?)
             "INCOMPLETE: the registered-filter listing did not finish; filters missing from it are unknown, not absent."]
            [(hash-ref report 'degraded #f)
             "Registry listing complete. Runtime view unavailable without administrator rights; this is not proof of file recovery."]
            [else "Enumeration completed; this is not proof of file recovery."])))

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
