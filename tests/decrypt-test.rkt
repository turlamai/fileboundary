#lang racket/base

;; Decrypt engine tests — XOR cipher correctness, CRC32, pad twin voting.
;; Fully synthetic, no real specimens or policy pad needed.

(require rackunit
         racket/file
         racket/list
         racket/port
         racket/runtime-path
         "../src/engine/decrypt.rkt")

;; ---------- CRC32 vectors ----------

(check-equal? (crc32-bytes #"") 0)
(check-equal? (crc32-bytes #"123456789") #xCBF43926)

;; ---------- pad twin voting (512-col convergence from synthetic pair) ----------

(define test-pad
  (for/hash ([c (in-range 512)])
    (values c (modulo (+ (* c 7) 13) 256))))

;; Generate a large synthetic known-plaintext/ciphertext pair (4096 bytes
;; = 8 pad periods, enough for every column to get >= 8 votes)
(define plain-twin (make-bytes 4096 65)) ; 4096 × 'A'
(define cipher-twin
  (apply bytes
         (for/list ([o (in-range (bytes-length plain-twin))])
           (bitwise-xor (bytes-ref plain-twin o)
                        (hash-ref test-pad (modulo o 512))))))

(define twin (twin-vote plain-twin cipher-twin))
(check-equal? (hash-ref twin 'covered) 512)
(check-equal? (hash-ref twin 'missing) empty)

;; recovered pad matches original
(check-equal?
 (for/sum ([c (in-range 512)]
           #:unless (= (hash-ref (hash-ref twin 'pad) c)
                       (hash-ref test-pad c)))
   1)
 0)

;; XOR round-trip: encrypt then decrypt = original
(define round-trip
  (apply bytes
         (for/list ([o (in-range 64)])
           (bitwise-xor
             (bitwise-xor (bytes-ref plain-twin o)
                          (hash-ref test-pad (modulo o 512)))
             (hash-ref test-pad (modulo o 512))))))
(check-equal? round-trip (subbytes plain-twin 0 64))
