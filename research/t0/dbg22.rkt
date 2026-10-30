#lang racket/base
(require "../../src/engine/decrypt.rkt" racket/file racket/list)
(define pad (load-pad "research/t0/pad_full.json"))
(define ct
  (file->bytes "research/t0/fixtures/esafenet-wrapped-courseware.pdf"))
(define s (xor-pad ct pad))
(define hdr (find-xref-table s 512))
(displayln (format "hdr: ~a" hdr))
(when hdr
  (define count (car hdr))
  (define tstart (cdr hdr))
  (displayln (format "count=~a tstart=~a" count tstart))
  (for ([k (in-range 5)])
    (define rp (+ tstart (* 20 k)))
    (displayln
     (format "  rec ~a: ~a | byte17=~a"
             k (subbytes s rp (+ rp 20))
             (bytes-ref (subbytes s rp (+ rp 20)) 17)))))
