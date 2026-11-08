#lang racket/base

;; Signed update pipeline (docs/update-contract.md, ADR-0011): the same
;; rivet/distribution managed updater the family products run. The backend
;; owns trust (Ed25519-signed channel manifest, authenticate-before-parse),
;; transfer (deadline-bounded download with stall/total watchdogs) and the
;; phase state the RPC layer polls; the native host owns installation
;; (MSI handoff / portable zip swap). The legacy SHA-256-only manifest
;; channel (ADR-0008 as originally written) is retired — old clients get
;; an honest fetch failure instead of a compatibility shroud.

(require rivet/distribution
         json
         racket/file
         racket/path
         racket/string
         "../src/version.rkt")

(provide update-public-key-b64
         update-key-id
         default-feed-url
         update-data-dir
         settings-path
         setting-ref setting-set!
         settings-adapter
         resolve-flavor
         make-app-updater
         current-updater!
         update-flavor!
         update-check-update!
         update-start-or-cancel-download!
         update-state-snapshot
         stamp-silent-checked!
         ;; re-exported rivet managed-updater surface for the CLI's thin
         ;; update commands (keeps the rivet require in exactly one app file)
         updater? make-updater
         updater-check! updater-download! updater-cancel! updater-wait
         updater-state)

;; The updater trust root: SPKI DER of the Ed25519 public key whose
;; private half lives in the GitHub secret RIVET_UPDATE_PRIVATE_KEY.
;; Regenerate with scripts/update-keys.sh; rotation policy in
;; docs/update-contract.md. scripts/check-release-signing-key.sh parses
;; this define (keep the literal on its own line below the define).
(define update-public-key-b64
  "MCowBQYDK2VwAyEArvV2uAAWCwR4Gxym7V4gmsnq6f140fp4MzporEbx2Oc=")

(define update-key-id "fileboundary-2026-11")

;; Manifest fetch uses the moving latest feed; artifact URLs inside the
;; signed manifest are pinned to the concrete release tag.
(define default-feed-url
  "https://github.com/turlamai/fileboundary/releases/latest/download/update-stable.json")

;; ---- operator settings (per-user, never the install tree) ----

(define (update-data-dir)
  (define base (or (getenv "LOCALAPPDATA") (path->string (find-system-path 'home-dir))))
  (build-path base "FileBoundary"))

;; A parameter so tests can redirect the store instead of touching the
;; operator's real settings.
(define settings-path
  (make-parameter (build-path (update-data-dir) "settings.json")))

(define (read-settings)
  (with-handlers ([exn:fail? (lambda (_) (hasheq))])
    (define parsed (with-input-from-file (settings-path) read-json))
    (if (hash? parsed) (hash->hasheq-immutable parsed) (hasheq))))

(define (hash->hasheq-immutable h)
  (for/hasheq ([(k v) (in-hash h)])
    (values k (if (hash? v) (hash->hasheq-immutable v) v))))

(define (setting-ref key [fallback ""])
  (define value (hash-ref (read-settings) (string->symbol key) fallback))
  (cond
    [(string? value) value]
    [(exact-integer? value) (number->string value)]
    [else fallback]))

(define (setting-set! key value)
  (define destination (settings-path))
  (make-directory* (path-only destination))
  (define updated (hash-set (read-settings) (string->symbol key) value))
  ;; atomic-ish: write a sibling temp, then rename over the real file
  (define tmp
    (build-path (path-only destination)
                (format "settings.tmp.~a.~a.json"
                        (current-milliseconds) (random 1000000))))
  (with-output-to-file tmp
    (lambda () (write-json updated)) #:exists 'truncate)
  (rename-file-or-directory tmp destination #t))

;; The scaffold's sticky rollout bucket: one 0-99 value per installation,
;; drawn once from OS entropy and persisted.
(define settings-adapter
  (updater-settings-adapter
   (lambda (key) (setting-ref key #f))
   (lambda (key value) (setting-set! key value))))

;; ---- flavor and updater construction ----

;; Host-reported install flavor ("zip" portable layout or "msi" Program
;; Files install); stamped before every check so the signed manifest's
;; matching artifact is selected.
(define (resolve-flavor flavor-string)
  (case (string-trim (or flavor-string ""))
    [("zip") 'portable]
    [("msi") 'msi]
    [else #f]))

(define (make-app-updater #:feed-url [feed-url default-feed-url]
                          #:install-kind [install-kind #f]
                          #:current-version [version product-version]
                          #:public-key [public-key update-public-key-b64]
                          #:key-id [key-id update-key-id]
                          #:data-directory [data-dir (update-data-dir)]
                          #:rollout-bucket [bucket #f])
  (make-updater
   #:application-id "dev.turlamai.fileboundary"
   #:current-version version
   #:channel 'stable
   #:install-kind install-kind
   #:public-key
   ;; accepts the embedded base64 SPKI DER or the raw DER bytes
   (if (bytes? public-key) public-key (base64-string->bytes public-key))
   #:key-id key-id
   #:manifest-url feed-url
   #:data-directory data-dir
   #:rollout-bucket
   (or bucket (resolve-rollout-bucket! settings-adapter))))

;; The process-wide updater; rebuilt when the install flavor changes so a
;; late-stamped host flavor still selects the matching artifact.
(define updater-box (box (make-app-updater)))

(define (current-updater!) (unbox updater-box))

(define (update-flavor! flavor-string)
  (set-box! updater-box
            (make-app-updater #:install-kind (resolve-flavor flavor-string))))

;; ---- RPC-facing operations ----

;; A settled check: the result the caller reports AND the throttle stamp
;; (a stamp means an answer or a definitive failure — never a merely
;; attempted one, so one offline launch cannot silence four hours).
(define (update-check-update!)
  (begin0
    (updater-check! (current-updater!))
    (stamp-silent-checked!)))

(define (stamp-silent-checked!)
  (with-handlers ([exn:fail? void])
    (setting-set! "last-update-check" (number->string (current-seconds)))))

;; taskly's start/cancel toggle: starting a download cancels a running
;; one; the phase box (update-state-snapshot) is the only shared state.
(define (update-start-or-cancel-download!)
  (define instance (current-updater!))
  (with-handlers
      ([exn:fail?
        (lambda (error)
          (jsexpr->string
           (hasheq 'status "error" 'message (exn-message error))))])
    (define phase (hash-ref (updater-state instance) 'phase))
    (cond
      [(equal? phase "downloading") (updater-cancel! instance)]
      [(equal? phase "available") (updater-download! instance)])
    (jsexpr->string (updater-state instance))))

(define (update-state-snapshot)
  (jsexpr->string (updater-state (current-updater!))))
