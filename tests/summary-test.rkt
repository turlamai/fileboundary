#lang racket/base

(require rackunit
         racket/file
         racket/path
         racket/string
         "../src/engine/summary.rkt")

(define (record kind)
  (hash 'classification kind))

(check-equal? (scan-statistics '())
              (hash 'total 0 'recognizedWrapper 0 'other 0))
(check-equal?
 (scan-statistics (list (record "encrypted-recognized")
                        (record "unknown")
                        (record "encrypted-recognized")))
 (hash 'total 3 'recognizedWrapper 2 'other 1))

(define root (make-temporary-file "fileboundary-gui-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (call-with-output-file (build-path root "sample.pdf")
     (lambda (out) (write-bytes #"%PDF-1.7\nSynthetic invalid PDF" out))
     #:mode 'binary #:exists 'error)
   (let ([message (scan-summary (path->string root) #:max-files 5)])
     (check-true (string-contains? message "Inspected: 1 file"))
     (check-true (string-contains? message "Signatures do not prove plaintext"))
     (check-false (string-contains? message (path->string root)))))
 (lambda () (delete-directory/files root)))

(define verify-root (make-temporary-file "fileboundary-verify-gui-~a" 'directory))
(dynamic-wind
 void
 (lambda ()
   (let ([original (build-path verify-root "encrypted-sample.pdf")]
         [candidate (build-path verify-root "approved-export.pdf")])
     (call-with-output-file original
       (lambda (out)
         (write-bytes
          (bytes-append (bytes 98 20 35 101 188 1 68 0)
                        #"E-SafeNet LOCK synthetic") out))
       #:mode 'binary #:exists 'error)
     (call-with-output-file candidate
       (lambda (out)
         (write-bytes #"%PDF-1.7\nstartxref\n0\n%%EOF\n" out))
       #:mode 'binary #:exists 'error)
     (let ([result (verify-export-summary (path->string original)
                                          (path->string candidate))])
       (check-true (string-contains? result "UNVERIFIED"))
       (check-true (string-contains? result "No decryption performed"))
       (check-false (string-contains? result (path->string verify-root))))
     (let ([result (verify-export-summary (path->string original)
                                          (path->string original))])
       (check-true (string-contains? result "FAILED"))
       (check-true (string-contains? result "exportStillEncryptedWrapper")))))
 (lambda () (delete-directory/files verify-root)))

;; Input failures are never presented as a successful read-only operation.
(define missing-status
  (verify-export-summary
   "missing-original-never-created-fileboundary.pdf"
   "missing-export-never-created-fileboundary.pdf"))
(check-true (string-contains? missing-status "Authorized export comparison: ERROR"))
(check-false (string-contains? missing-status "UNVERIFIED"))

;; ---- doctor summary ------------------------------------------------------
;;
;; The operator reads this text in the GUI. It must lead with the
;; encryption-class filters (the service Group is authoritative), and an
;; incomplete registry listing must be called out - a truncated listing
;; once presented "19 registered filters, complete" while the encryption
;; filter sat in the dropped half of the alphabet.

(define (doctor-check status)
  (hash 'status status 'exitCode 0 'stdout "" 'stderr "" 'truncated #f
        'capturedAtUnixMs 0 'durationMs 0))

(define (doctor-report* registry-status registry-filters)
  (hash 'checks
        (hash 'filters (doctor-check "requiresElevation")
              'instances (doctor-check "requiresElevation")
              'registryFilters (hash-set* (doctor-check registry-status)
                                          'filters registry-filters
                                          'filterCount (length registry-filters)
                                          'source "registry-api")
              'signatureHeuristics (hash 'matchedNames '("MEDLP.exe")
                                         'encryptionGroup '("TsdEncryptMF")))
        'degraded #f 'evidence "measured" 'scope "read-only-diagnostics"))

(define zdrv (hash 'name "zdrv" 'altitudes '("149000") 'group "FSFilter Encryption" 'start 1))
(define wdfilter (hash 'name "WdFilter" 'altitudes '("328010") 'group "FSFilter Anti-Virus" 'start 3))

(define complete (doctor-summary (doctor-report* "ok" (list wdfilter zdrv))))
(check-true (string-contains? complete "Encryption-group filter drivers (Group = FSFilter Encryption): 1"))
(check-true (string-contains? complete "zdrv"))
(check-true (string-contains? complete "Registered filter drivers: 2"))
(check-false (string-contains? complete "INCOMPLETE"))
(check-true (string-contains? complete "requiresElevation"))

(define partial (doctor-summary (doctor-report* "timedOut" (list wdfilter))))
(check-true (string-contains? partial "INCOMPLETE"))
(check-true (string-contains? partial "timedOut"))
(check-true (string-contains? partial "Encryption-group filter drivers (Group = FSFilter Encryption): 0"))

;; An empty but successful listing is "none found", not "incomplete".
(define empty-ok (doctor-summary (doctor-report* "ok" '())))
(check-true (string-contains? empty-ok "(none found)"))
(check-false (string-contains? empty-ok "INCOMPLETE"))

;; rows from the reg.exe fallback carry no Group; the summary still renders
(define legacy (doctor-summary (doctor-report* "ok" (list (hash 'name "zdrv" 'altitudes '("149000"))))))
(check-true (string-contains? legacy "zdrv"))
