#lang racket/base

(require rivet/backend
         racket/file
         racket/list
         racket/path
         racket/string
         (prefix-in domain: "../src/engine/summary.rkt")
         (prefix-in dec: "../src/engine/decrypt.rkt"))

(provide start)

(define-rpc (scan-summary [source : String] : String)
  (domain:scan-summary source #:max-files 200))

(define-rpc (doctor-summary : String)
  (domain:doctor-summary))

(define-rpc (verify-export-summary [original : String] [exported : String] : String)
  (domain:verify-export-summary original exported))

;; decrypt helper: standalone function (not inside define-rpc body,
;; which does not support internal defines)
(define (do-decrypt input-path output-path)
  (define pad-path
    (build-path (path->complete-path
                 (simple-form-path input-path))
                "up" "up" "up" "research" "t0" "pad_full.json"))
  (define pad (dec:load-pad pad-path))
  (define ct (file->bytes input-path))
  (define r (dec:decrypt-ooxml ct pad))
  (define entries (hash-ref r 'entries))
  (define verified (hash-ref r 'verified))
  (define total (hash-ref r 'total))
  (define standalone (hash-ref r 'bytes))
  (with-output-to-file output-path
    (lambda () (write-bytes standalone))
    #:exists 'replace)
  (format "{\"verified\":~a,\"total\":~a,\"entries\":[~a]}"
          verified total
          (string-join
           (for/list ([e entries])
             (define nm (bytes->string/utf-8 (hash-ref e 'name)))
             (define safe (regexp-replace* "[\"\\\\]" nm "\\\\$0"))
             (format "{\"name\":\"~a\",\"crcOk\":~a}"
                     safe (if (hash-ref e 'crcOk) "true" "false")))
           ",")))

(define-rpc (decrypt-summary [input : String] [output : String] : String)
  (do-decrypt input output))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
