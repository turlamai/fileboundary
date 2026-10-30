#lang racket/base
(require "../../src/engine/decrypt.rkt" racket/file racket/list)
(define pad (load-pad "research/t0/pad_full.json"))
(define ct
  (file->bytes "research/t0/fixtures/esafenet-wrapped-courseware.pdf"))
(define gate-failed #f)
(define original
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (displayln (format "gate: ~a" (exn-message e)))
                     (set! gate-failed #t)
                     #f)])
    (hash-ref (decrypt-pdf ct pad) 'bytes)))
(when original
  (define hdr (find-xref-table original
                               (max 0 (- (bytes-length original) 65536))))
  (displayln (format "table: ~a" hdr))
  (when hdr
    (for ([k (in-range 6)])
      (define rp (+ (cdr hdr) (* 20 k)))
      (define rec (subbytes original rp (+ rp 20)))
      (define off (string->number (bytes->string/utf-8 (subbytes rec 0 10))))
      (displayln
       (format "  rec ~a: kind=~a off=~a landing=~a"
               k (bytes->string/utf-8 (subbytes rec 17 18)) off
               (if off
                   (subbytes original off
                             (min (+ off 16) (bytes-length original)))
                   #""))))))
