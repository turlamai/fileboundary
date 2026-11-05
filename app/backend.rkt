#lang racket/base

(require rivet/backend
         json
         racket/list
         racket/path
         racket/string
         (prefix-in domain: "../src/engine/summary.rkt")
         (prefix-in dec: "../src/engine/decrypt.rkt")
         (prefix-in upd: "../src/engine/update.rkt")
         "../src/version.rkt")

(provide start)

;; The GUI delegates to the same Racket domain functions as the headless tools.
;; No file contents or local paths are returned in RPC responses.
(define-rpc (scan-summary [source : String] : String)
  (domain:scan-summary source #:max-files 200))

(define-rpc (doctor-summary : String)
  (domain:doctor-summary))

;; Both file paths must be supplied by the operator; no automatic decrypted
;; content export and no DLP process-policy interaction occurs here.
(define-rpc (verify-export-summary [original : String] [exported : String] : String)
  (domain:verify-export-summary original exported))

;; decrypt: the GUI panel delegates to the same engine entry as
;; `racket src/cli.rkt decrypt` (OOXML first, PDF fallback). The response
;; carries per-entry CRC verdicts only — names, booleans and counters,
;; never file contents (RPC hygiene). The policy pad is operator key
;; material: the caller supplies a pad file path (GUI key picker or CLI
;; --pad) — there is no implicit resolution and key material is never
;; packaged with the app; a missing pad surfaces as a bounded RPC error.
(define-rpc (decrypt-summary [input : String] [output : String] [pad : String] : String)
  (define report (dec:decrypt-file input output pad))
  (define out-name
    (path->string (file-name-from-path (simple-form-path output))))
  (if (equal? (hash-ref report 'kind) "pdf")
      (jsexpr->string
       (hash 'kind "pdf"
             'headRebuilt (hash-ref report 'headRebuilt)
             'pages (hash-ref report 'pages)
             'coverObject (hash-ref report 'coverObject)
             'xrefChecked (hash-ref report 'xrefChecked)
             'xrefBad (hash-ref report 'xrefBad)
             'output out-name))
      (jsexpr->string
       (hash 'kind "ooxml"
             'verified (hash-ref report 'verified)
             'total (hash-ref report 'total)
             'entries (for/list ([e (in-list (hash-ref report 'entries '()))])
                        (hash 'name (hash-ref e 'name)
                              'crcOk (hash-ref e 'crcOk)))
             'output out-name))))

;; pad twin: the GUI panel delegates to the same engine entry as
;; `racket src/cli.rkt pad twin`. The recovered pad is operator key
;; material: it is written only to the operator-supplied output path and
;; never returned over the wire — the response carries coverage counters
;; (covered/missingCount/complete) and the output file name only.
(define-rpc (pad-twin-summary [plain : String] [cipher : String] [output : String] : String)
  (define r (dec:write-twin-pad plain cipher output))
  (define missing (hash-ref r 'missing))
  (jsexpr->string
   (hash 'covered (hash-ref r 'covered)
         'missingCount (length missing)
         'complete (null? missing)
         'output (path->string
                  (file-name-from-path (simple-form-path output))))))

;; update check: the GUI delegates to the same engine entry as
;; `racket src/cli.rkt update check` (ADR-0008 channel). The manifest
;; URL is the default release channel unless the caller supplies one.
;; Returns current version, latest version, and whether an update is
;; available — enough for the UI to inform the operator without any
;; push mechanism (every network access is explicit and operator-
;; initiated per ADR-0008).
(define default-channel-url
  "https://github.com/turlamai/fileboundary/releases/latest/download/manifest.json")

(define-rpc (update-check-summary [manifest : String] : String)
  (define source
    (if (string=? (string-trim manifest) "")
        default-channel-url
        (string-trim manifest)))
  (define m (upd:fetch-manifest source))
  (define result (upd:check-update m product-version))
  (jsexpr->string
   (hash 'updateAvailable (hash-ref result 'updateAvailable #f)
         'currentVersion product-version
         'latestVersion (hash-ref result 'latestVersion "")
         'action (hash-ref result 'action ""))))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
