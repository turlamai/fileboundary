#lang racket/base
(require "../../src/engine/decrypt.rkt" racket/file)
(define pad (load-pad "research/t0/pad_full.json"))
(define ct
  (file->bytes "research/t0/fixtures/esafenet-wrapped-courseware.pdf"))
(define s (xor-pad ct pad))
(define obj-end (bytes-find s #"endobj" 512))
(displayln (format "obj-end=~a" obj-end))
(displayln (format "s[~a:~a]: ~a" (- obj-end 4) (+ obj-end 10)
                   (subbytes s (- obj-end 4) (+ obj-end 10))))
