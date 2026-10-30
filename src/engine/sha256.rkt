#lang racket/base

;; Dependency-free SHA-256 (FIPS 180-4) for package integrity checks.
;; Performance is adequate for CI and update packages (tens of MB); it is
;; deliberately NOT a general-purpose high-throughput hasher.

(require racket/vector
         racket/file)

(provide sha256-bytes sha256-file sha256-hex)

(define (rol32 x n)
  (bitwise-and 4294967295
               (bitwise-ior (arithmetic-shift x n)
                            (arithmetic-shift x (- n 32)))))

(define K
  (list->vector
   '(#x428a2f98 #x71374491 #xb5c0fbcf #xe9b5dba5 #x3956c25b #x59f111f1
     #x923f82a4 #xab1c5ed5 #xd807aa98 #x12835b01 #x243185be #x550c7dc3
     #x72be5d74 #x80deb1fe #x9bdc06a7 #xc19bf174 #xe49b69c1 #xefbe4786
     #x0fc19dc6 #x240ca1cc #x2de92c6f #x4a7484aa #x5cb0a9dc #x76f988da
     #x983e5152 #xa831c66d #xb00327c8 #xbf597fc7 #xc6e00bf3 #xd5a79147
     #x06ca6351 #x14292967 #x27b70a85 #x2e1b2138 #x4d2c6dfc #x53380d13
     #x650a7354 #x766a0abb #x81c2c92e #x92722c85 #xa2bfe8a1 #xa81a664b
     #xc24b8b70 #xc76c51a3 #xd192e819 #xd6990624 #xf40e3585 #x106aa070
     #x19a4c116 #x1e376c08 #x2748774c #x34b0bcb5 #x391c0cb3 #x4ed8aa4a
     #x5b9cca4f #x682e6ff3 #x748f82ee #x78a5636f #x84c87814 #x8cc70208
     #x90befffa #xa4506ceb #xbef9a3f7 #xc67178f2)))

(define M32 4294967296) ; 2^32

(define (add32 . xs)
  (modulo (apply + xs) M32))

(define (sha256-block! H block)
  (define w (make-vector 64 0))
  (for ([i (in-range 16)])
    (vector-set! w i
                 (+ (* (bytes-ref block (* 4 i)) 16777216)
                    (* (bytes-ref block (+ (* 4 i) 1)) 65536)
                    (* (bytes-ref block (+ (* 4 i) 2)) 256)
                    (bytes-ref block (+ (* 4 i) 3)))))
  (for ([i (in-range 16 64)])
    (define w15 (vector-ref w (- i 15)))
    (define w2 (vector-ref w (- i 2)))
    (define s0 (bitwise-xor (rol32 w15 25) (rol32 w15 14)
                            (arithmetic-shift w15 -3)))
    (define s1 (bitwise-xor (rol32 w2 15) (rol32 w2 13)
                            (arithmetic-shift w2 -10)))
    (vector-set! w i
                 (add32 (vector-ref w (- i 16)) s0
                        (vector-ref w (- i 7)) s1)))
  (define a (vector-ref H 0))
  (define b (vector-ref H 1))
  (define c (vector-ref H 2))
  (define d (vector-ref H 3))
  (define e (vector-ref H 4))
  (define f (vector-ref H 5))
  (define g (vector-ref H 6))
  (define h (vector-ref H 7))
  (for ([i (in-range 64)])
    (define S1 (bitwise-xor (rol32 e 26) (rol32 e 21) (rol32 e 7)))
    (define ch (bitwise-xor (bitwise-and e f)
                            (bitwise-and (bitwise-xor e (- M32 1)) g)))
    (define t1 (add32 h S1 ch (vector-ref K i) (vector-ref w i)))
    (define S0 (bitwise-xor (rol32 a 30) (rol32 a 19) (rol32 a 10)))
    (define maj (bitwise-xor (bitwise-and a b)
                             (bitwise-and a c)
                             (bitwise-and b c)))
    (define t2 (add32 S0 maj))
    (set! h g)
    (set! g f)
    (set! f e)
    (set! e (add32 d t1))
    (set! d c)
    (set! c b)
    (set! b a)
    (set! a (add32 t1 t2)))
  (vector-set! H 0 (add32 (vector-ref H 0) a))
  (vector-set! H 1 (add32 (vector-ref H 1) b))
  (vector-set! H 2 (add32 (vector-ref H 2) c))
  (vector-set! H 3 (add32 (vector-ref H 3) d))
  (vector-set! H 4 (add32 (vector-ref H 4) e))
  (vector-set! H 5 (add32 (vector-ref H 5) f))
  (vector-set! H 6 (add32 (vector-ref H 6) g))
  (vector-set! H 7 (add32 (vector-ref H 7) h)))

(define initial-H
  (vector #x6a09e667 #xbb67ae85 #x3c6ef372 #xa54ff53a
          #x510e527f #x9b05688c #x1f83d9ab #x5be0cd19))

(define (sha256-bytes data)
  (define H (vector-copy initial-H))
  (define len (bytes-length data))
  (define with-80 (bytes-append data (bytes #x80)))
  ;; pad with zeros so that len+1+k = 56 (mod 64), leaving room for the
  ;; 8-byte big-endian bit length
  (define zeros (make-bytes (modulo (- 56 (+ len 1)) 64) 0))
  (define bit-len (* 8 len))
  (define full (bytes-append with-80 zeros
                             (integer->integer-bytes bit-len 8 #f #t)))
  (for ([off (in-range 0 (bytes-length full) 64)])
    (sha256-block! H (subbytes full off (+ off 64))))
  (apply bytes-append
         (for/list ([i (in-range 8)])
           (integer->integer-bytes (vector-ref H i) 4 #f #t))))

(define (sha256-hex data)
  (apply string-append
         (for/list ([b (in-bytes (sha256-bytes data))])
           (let ([s (format "~x" b)])
             (if (= (string-length s) 1) (string-append "0" s) s)))))

(define (sha256-file path)
  ;; correctness-first: whole-file read. Update packages are tens of MB.
  (sha256-hex (file->bytes path)))
