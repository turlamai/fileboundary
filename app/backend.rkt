#lang racket/base

(require rivet/backend
         json
         racket/list
         racket/path
         racket/string
         (prefix-in domain: "../src/engine/summary.rkt")
         (prefix-in dec: "../src/engine/decrypt.rkt")
         (prefix-in upd: "update.rkt")
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
       (hash 'kind (hash-ref report 'kind)
             'verified (hash-ref report 'verified)
             'total (hash-ref report 'total)
             'lostCount (length (hash-ref report 'lostEntries '()))
             'decryptedInner (hash-ref report 'decryptedInner 0)
             'entries (for/list ([e (in-list (hash-ref report 'entries '()))])
                        (hash 'name (hash-ref e 'name)
                              'crcOk (hash-ref e 'crcOk)
                              'lost (hash-ref e 'lost #f)
                              'wrapped (hash-ref e 'wrapped #f)
                              'innerKind (hash-ref e 'innerKind #f)))
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

;; update: the GUI drives the signed update pipeline (docs/update-contract.md,
;; ADR-0011) through the same state machine the family products run — check
;; reports available/up-to-date/error and settles the silent-check throttle
;; stamp, download is a start/cancel toggle, and the phase state is polled.
;; The host owns installation; the backend never installs.
(define (update-settings-whitelist op key)
  (case op
    [("get") (member key '("install-flavor" "auto-check-updates"
                           "last-update-check"))]
    [("set") (member key '("install-flavor" "auto-check-updates"))]
    [else #f]))

(define-rpc (update-settings-get [key : String] : String)
  (if (update-settings-whitelist "get" key)
      (upd:setting-ref key)
      (error 'update-settings-get "setting key not allowed: ~a" key)))

(define-rpc (update-settings-set [key : String] [value : String] : String)
  (unless (update-settings-whitelist "set" key)
    (error 'update-settings-set "setting key not allowed: ~a" key))
  (upd:setting-set! key value)
  (when (equal? key "install-flavor") (upd:update-flavor! value))
  (upd:setting-ref key))

(define-rpc (update-check : String)
  (jsexpr->string (upd:update-check-update!)))

(define-rpc (update-download : String)
  (upd:update-start-or-cancel-download!))

(define-rpc (update-state : String)
  (upd:update-state-snapshot))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
