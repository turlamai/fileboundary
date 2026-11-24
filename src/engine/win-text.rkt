#lang racket/base

;; Tiny helpers shared by the Windows FFI modules. Racket ships no
;; UTF-16 byte-string decoder, and the registry and MultiByteToWideChar
;; both hand out little-endian UTF-16.
(provide pointer->bytes utf16le->string)

(require ffi/unsafe)

;; Copy n bytes out of a raw malloc block into a byte string.
(define (pointer->bytes p n)
  (define out (make-bytes n))
  (for ([i (in-range n)])
    (bytes-set! out i (ptr-ref p _uint8 i)))
  out)

;; Decode little-endian UTF-16, trailing NUL dropped, surrogate pairs
;; folded; an unpaired surrogate becomes U+FFFD rather than raising.
(define (utf16le->string raw)
  (define units (quotient (bytes-length raw) 2))
  (define (unit i)
    (integer-bytes->integer (subbytes raw (* 2 i) (* 2 (add1 i))) #f #f))
  (define end
    (let loop ([i units])
      (if (and (> i 0) (zero? (unit (sub1 i)))) (loop (sub1 i)) i)))
  (let loop ([i 0] [acc '()])
    (if (>= i end)
        (list->string (reverse acc))
        (let* ([u (unit i)]
               [lo (and (>= u #xD800) (<= u #xDBFF) (< (add1 i) end) (unit (add1 i)))]
               [paired (and lo (>= lo #xDC00) (<= lo #xDFFF)
                            (+ #x10000 (* #x400 (- u #xD800)) (- lo #xDC00)))])
          (cond
            [paired (loop (+ i 2) (cons (integer->char paired) acc))]
            [(and (>= u #xD800) (<= u #xDFFF))
             (loop (add1 i) (cons #\uFFFD acc))]
            [else (loop (add1 i) (cons (integer->char u) acc))])))))
