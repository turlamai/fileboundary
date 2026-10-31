#lang racket/base
(require net/url racket/port)
(displayln (procedure-arity get-pure-port))
(displayln (format "arity: ~a" (procedure-arity get-pure-port)))
;; real call with keyword
(define in (get-pure-port (string->url "https://api.github.com/rate_limit")))
(define b (port->bytes in))
(close-input-port in)
(displayln (format "got ~a bytes" (bytes-length b)))
