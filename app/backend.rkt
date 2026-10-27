#lang racket/base

(require rivet/backend
         (prefix-in domain: "../src/engine/summary.rkt"))

(provide start)

;; The GUI delegates to the same Racket domain functions as the headless tools.
;; No file contents or local paths are returned in RPC responses.
(define-rpc (scan-summary [source : String] : String)
  (domain:scan-summary source #:max-files 200))

(define-rpc (doctor-summary : String)
  (domain:doctor-summary))

(define (start in-fd out-fd)
  (serve-fds in-fd out-fd))
