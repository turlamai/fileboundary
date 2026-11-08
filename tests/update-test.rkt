#lang racket/base

;; Update pipeline tests (ADR-0011): trust-root sanity, the operator
;; settings store, Ed25519 manifest sign/verify with a throwaway keypair,
;; select-update gates (key id, rollout bucket, install flavor, app id,
;; downgrades), the managed updater's check/download lifecycle over a
;; loopback HTTP server with signed-artifact verification, the CLI
;; envelope surface, and the MSVCRT argv quoting the spawn path relies
;; on. No external network anywhere: manifests are signed in-process and
;; artifacts come from a local TCP listener.

(require rackunit
         json
         racket/async-channel
         racket/file
         racket/list
         racket/path
         racket/port
         racket/runtime-path
         racket/string
         racket/tcp
         (prefix-in rivet: rivet/distribution)
         (prefix-in rivet-ts: (submod rivet/distribution/managed-updater test-support))
         (prefix-in upd: "../app/update.rkt")
         "../src/engine/sha256.rkt"
         "../src/engine/winproc.rkt"
         "../src/version.rkt")

(define-runtime-path cli-path "../src/cli.rkt")

;; ---------- SHA-256 (FIPS 180-4 vectors) ----------

(check-equal? (sha256-hex #"")
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
(check-equal? (sha256-hex #"abc")
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
(check-equal? (sha256-hex #"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

;; file hashing agrees with byte hashing
(define tmp0 (make-temporary-file "fb-sha~a.txt"))
(displayln "hello sha" (open-output-file tmp0 #:exists 'replace))
(check-equal? (sha256-file tmp0) (sha256-hex (file->bytes tmp0)))
(delete-file tmp0)

;; ---------- MSVCRT argv quoting (CreateProcessW path) ----------

(check-equal? (windows-quote-arg "") "\"\"")
(check-equal? (windows-quote-arg "plain.exe") "plain.exe")
(check-equal? (windows-quote-arg "C:/Users/foo bar/out.txt")
              "\"C:/Users/foo bar/out.txt\"")
;; embedded quote is escaped, and backslashes before it double
(check-equal? (windows-quote-arg "a\"b") "\"a\\\"b\"")
;; bare arguments (no whitespace/quote) pass through unquoted
(check-equal? (windows-quote-arg "C:/dir/") "C:/dir/")
(check-equal? (windows-quote-arg "C:/dir\\") "C:/dir\\")
;; backslashes double only when they immediately precede a quote
;; (MSVCRT rule): a trailing backslash before a space stays single
(check-equal? (windows-quote-arg "C:/dir\\ ") "\"C:/dir\\ \"")

;; ---------- trust root ----------

(define trust-root-bytes (rivet:base64-string->bytes upd:update-public-key-b64))
(check-equal? (bytes-length trust-root-bytes) 44)  ; Ed25519 SPKI DER
(check-not-false (rivet:bytes->ed25519-public-key trust-root-bytes))
(check-false (string=? upd:update-key-id ""))
(check-true (string-prefix? upd:default-feed-url "https://"))

;; ---------- operator settings store ----------

;; redirected store: tests never touch the operator's real settings
(define settings-test-dir
  (build-path (find-system-path 'temp-dir) "fb-update-test-settings"))
(define settings-test-path
  (build-path settings-test-dir "settings.json"))

(check-equal? (parameterize ([upd:settings-path settings-test-path])
                (upd:setting-ref "auto-check-updates" "1"))
              "1")

(parameterize ([upd:settings-path settings-test-path])
  (upd:setting-set! "auto-check-updates" "0")
  (check-equal? (upd:setting-ref "auto-check-updates" "1") "0")
  (upd:setting-set! "auto-check-updates" "1")
  (check-equal? (upd:setting-ref "auto-check-updates" "1") "1"))

;; the sticky rollout bucket: drawn once from OS entropy, persisted, and
;; redrawn when the stored value is corrupt — never an error at startup
(parameterize ([upd:settings-path settings-test-path])
  (define first-bucket (rivet:resolve-rollout-bucket! upd:settings-adapter))
  (check-pred (λ (b) (and (exact-integer? b) (<= 0 b 99))) first-bucket)
  (check-equal? (upd:setting-ref "update.rollout-bucket")
                (number->string first-bucket))
  ;; sticky: the same bucket comes back on the next read
  (check-equal? (rivet:resolve-rollout-bucket! upd:settings-adapter)
                first-bucket)
  ;; corrupt value → redrawn, still in range
  (upd:setting-set! "update.rollout-bucket" "garbage")
  (define redrawn (rivet:resolve-rollout-bucket! upd:settings-adapter))
  (check-pred (λ (b) (and (exact-integer? b) (<= 0 b 99))) redrawn))

;; install flavor mapping
(check-equal? (upd:resolve-flavor "zip") 'portable)
(check-equal? (upd:resolve-flavor "msi") 'msi)
(check-equal? (upd:resolve-flavor "") #f)
(check-equal? (upd:resolve-flavor "tarball") #f)

;; ---------- manifest sign / verify (throwaway Ed25519 keypair) ----------

;; the key readers take file paths, so materialize the throwaway DERs
(define test-key-dir
  (build-path (find-system-path 'temp-dir) "fb-update-test-keys"))
(make-directory* test-key-dir)
(define test-priv-key-path (build-path test-key-dir "test-priv.der"))
(define test-pub-key-path (build-path test-key-dir "test-pub.der"))
(void (call-with-output-file test-priv-key-path
  (λ (out)
    (write-bytes
     (rivet:base64-string->bytes
      ;; throwaway keypair generated for this suite only — trusts nothing
      "MC4CAQAwBQYDK2VwBCIEILaqmQwkwXJ6iF0LRyDAGL/mMwpc+JIxju6yME/JGIj7")
     out))
  #:exists 'truncate))
(void (call-with-output-file test-pub-key-path
  (λ (out)
    (write-bytes
     (rivet:base64-string->bytes
      "MCowBQYDK2VwAyEA1TMdwuhDmXLAeeix74yWC7VKUB/5S0yQ9KGQYaCdQgE=")
     out))
  #:exists 'truncate))
(define test-priv-key (rivet:read-ed25519-private-key test-priv-key-path))
(define test-pub-key (rivet:read-ed25519-public-key test-pub-key-path))
(define test-key-id "fileboundary-test-2026-11")

(define payload (string->bytes/utf-8 "fileboundary update artifact payload"))
(define payload-sha (sha256-hex payload))
(define payload-size (bytes-length payload))

(define (make-test-manifest #:version [version "0.7.0"]
                            #:rollout [rollout 100]
                            #:installer [installer 'zip]
                            #:url [url "https://example.invalid/fb.zip"]
                            #:application-id
                            [application-id "dev.turlamai.fileboundary"])
  (rivet:update-manifest
   application-id version 1 'stable "2026-11-08T00:00:00Z"
   "0.0.0" #f #t rollout
   (list (rivet:update-artifact 'windows 'x64 url
                                payload-sha payload-size installer '() #f))))

;; a correctly signed manifest verifies and parses
(define signed-wrapper
  (let ([out (open-output-bytes)])
    (rivet:write-signed-manifest (make-test-manifest)
                                 test-priv-key test-key-id out)
    (get-output-bytes out)))
(define verified
  (rivet:verify-signed-manifest (open-input-bytes signed-wrapper)
                                test-pub-key #:key-id test-key-id))
(check-equal? (rivet:update-manifest-version verified) "0.7.0")

;; negatives fail closed: wrong key id, wrong key, tampered payload
(check-exn exn:fail?
           (λ () (rivet:verify-signed-manifest
                  (open-input-bytes signed-wrapper)
                  test-pub-key #:key-id "some-other-key-id")))
(check-exn exn:fail?
           (λ () (rivet:verify-signed-manifest
                  (open-input-bytes signed-wrapper)
                  (rivet:bytes->ed25519-public-key trust-root-bytes)
                  #:key-id test-key-id)))

;; flip one base64 character of the payload blob: the decoded bytes
;; change, so the signature can no longer verify
(define wrapper-text (bytes->string/utf-8 signed-wrapper))
(define blob-start
  (cdr (car (regexp-match-positions #rx"\"payload\":\"" wrapper-text))))
(define flipped-char
  (if (equal? (substring wrapper-text blob-start (add1 blob-start)) "A")
      "B" "A"))
(define tampered-text
  (string-append (substring wrapper-text 0 blob-start)
                 flipped-char
                 (substring wrapper-text (add1 blob-start))))
(check-exn exn:fail?
           (λ () (rivet:verify-signed-manifest
                  (open-input-bytes (string->bytes/utf-8 tampered-text))
                  test-pub-key #:key-id test-key-id)))

;; ---------- select-update gates ----------

(define (config-for #:bucket [bucket 50]
                    #:version [version "0.6.12"]
                    #:public-key [public-key test-pub-key]
                    #:key-id [key-id test-key-id])
  (rivet:updater-config "dev.turlamai.fileboundary" version 'stable
                        'windows 'x64 public-key key-id bucket
                        (* 100 1024 1024) #f))

;; newer version within rollout → candidate
(check-not-false (rivet:select-update (config-for)
                                      (make-test-manifest)))
;; same or older version → nothing (downgrades are refused)
(check-false (rivet:select-update (config-for #:version "0.7.0")
                                  (make-test-manifest #:version "0.7.0")))
(check-false (rivet:select-update (config-for #:version "0.7.1")
                                  (make-test-manifest #:version "0.7.0")))
;; rollout gate: bucket >= rollout → withheld, bucket < rollout → offered
(check-false (rivet:select-update (config-for #:bucket 50)
                                  (make-test-manifest #:rollout 50)))
(check-not-false (rivet:select-update (config-for #:bucket 50)
                                      (make-test-manifest #:rollout 51)))
(check-false (rivet:select-update (config-for #:bucket 99)
                                  (make-test-manifest #:rollout 1)))
;; application identity gate: a mismatching manifest is rejected loudly
(check-exn exn:fail?
          (λ () (rivet:select-update
                 (config-for)
                 (make-test-manifest
                  #:application-id "dev.turlamai.otherapp"))))
;; install-kind gate: flavor picks the matching artifact
(check-false (rivet:select-update (config-for)
                                  (make-test-manifest)
                                  #:install-kind 'msi))
(check-not-false
 (rivet:select-update
  (config-for)
  (make-test-manifest #:installer 'msi)
  #:install-kind 'msi))

;; ---------- managed updater lifecycle (loopback feed + artifact) ----------

(define work-dir
  (build-path (find-system-path 'temp-dir) "fb-update-test-work"))
(define data-dir (build-path work-dir "data"))

;; one-shot HTTP/1.1 responder: the first accepted connection is served
;; `body`; further connections are answered with whatever was queued
;; last. Serve #f to close without a body (connection reset territory).
;; racket/tcp has no listener-port accessor, so bind a fixed candidate
;; port and step forward on a collision.
(define-values (server-listener server-port)
  (let try ([candidate (+ 21000 (random 20000))])
    (with-handlers ([exn:fail? (λ (_) (try (+ candidate 1)))])
      (values (tcp-listen candidate 8 #t) candidate))))
(define served-bodies (make-async-channel))
(define server-thread
  (thread
   (λ ()
     (let accept-next ()
       (define-values (in out) (tcp-accept server-listener))
       (handle-connection in out)
       (accept-next)))))
(define (handle-connection in out)
  ;; drain the request head: blocking read through the blank line
  (regexp-match #rx#"\r\n\r\n" in)
  (define body (sync/timeout 30 served-bodies))
  (cond
    [(bytes? body)
     (write-bytes
      (string->bytes/utf-8
       (format "HTTP/1.1 200 OK\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
               (bytes-length body)))
      out)
     (write-bytes body out)
     (close-output-port out)]
    [else
     (with-handlers ([exn:fail? void]) (close-output-port out))]))
(define (serve-next! body) (async-channel-put served-bodies body))

;; the fake fetch hands back a manifest whose artifact URL points at the
;; loopback server; the wrapper verification path is covered above
(define (fake-fetch url public-key
                    #:key-id [key-id #f]
                    #:trusted-keys [trusted-keys #f]
                    #:maximum-bytes [maximum-bytes #f])
  (rivet:update-manifest
   "dev.turlamai.fileboundary" "0.7.0" 1 'stable "2026-11-08T00:00:00Z"
   "0.0.0" #f #t 100
   (list (rivet:update-artifact
          'windows 'x64
          (format "http://127.0.0.1:~a/fb-0.7.0.zip" server-port)
          payload-sha payload-size 'zip '() #f))))

(define live-updater
  (parameterize ([rivet-ts:current-managed-fetch-manifest fake-fetch])
    (upd:make-app-updater
     #:feed-url "https://example.invalid/update-stable.json"
     #:current-version "0.6.12"
     #:public-key
     (rivet:base64-string->bytes
      "MCowBQYDK2VwAyEA1TMdwuhDmXLAeeix74yWC7VKUB/5S0yQ9KGQYaCdQgE=")
     #:key-id test-key-id
     #:data-directory data-dir
     #:rollout-bucket 50)))

;; happy path: check → available → download with the real downloader,
;; size+SHA verified against the signed artifact → downloaded state
(serve-next! payload)
(define check-result (rivet:updater-check! live-updater))
(check-equal? (hash-ref check-result 'status) "available")
(check-equal? (hash-ref check-result 'availableVersion) "0.7.0")
(check-equal? (hash-ref (rivet:updater-state live-updater) 'phase)
              "available")

(rivet:updater-download! live-updater)
(check-not-false (rivet:updater-wait live-updater 60))
(define downloaded-state (rivet:updater-state live-updater))
(check-equal? (hash-ref downloaded-state 'phase) "downloaded")
(check-equal? (hash-ref downloaded-state 'percent) 100)
(define downloaded-path (hash-ref downloaded-state 'downloadedPath))
(check-true (and (string? downloaded-path)
                 (not (string=? downloaded-path ""))))
(check-equal? (file->bytes (string->path downloaded-path)) payload)

;; tampered artifact: the server serves bytes that differ from the signed
;; sha256 — the download must end in the error phase and never land at
;; the destination
(serve-next! (string->bytes/utf-8 "TAMPERED bytes, not signed"))
(void (rivet:updater-check! live-updater))
(rivet:updater-download! live-updater)
(check-not-false (rivet:updater-wait live-updater 60))
(check-equal? (hash-ref (rivet:updater-state live-updater) 'phase) "error")

;; ---------- CLI envelope surface ----------

;; the status envelope is local-only: running version from the single
;; version source, flavor, toggle and feed present, no network
(define (run-capture args)
  (with-output-to-string
    (λ () ((dynamic-require cli-path 'run-cli) args))))

(define status-envelope
  (read-json (open-input-string (run-capture (list "update" "status")))))
(check-equal? (hash-ref status-envelope 'status) "ok")
;; a dev tree carries the +dev build-metadata suffix; prefix match keeps
;; the assertion independent of the checkout type
(check-true
 (string-prefix? (hash-ref (hash-ref status-envelope 'data) 'runningVersion)
                 version))
(check-equal? (hash-ref (hash-ref status-envelope 'data) 'feed)
              upd:default-feed-url)

;; the retired apply subcommand answers with a usage error
(define apply-envelope
  (read-json
   (open-input-string
    (run-capture
     (list "update" "apply" "--package" "x.zip" "--manifest" "m.json")))))
(check-equal? (hash-ref apply-envelope 'status) "error")
(check-equal? (hash-ref apply-envelope 'command) "update")
