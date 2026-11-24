#lang racket/base

;; The registry API enumeration must list every registered minifilter
;; without a child process. `reg query Services /s /f Altitude` was killed
;; by the 8 s diagnostic budget on a real developer machine and dropped
;; everything after "npsvctrig", hiding the encryption filter.
(require rackunit
         racket/list
         "../src/engine/winreg.rkt")

(define (non-empty-string? s) (and (string? s) (> (string-length s) 0)))

(define started (current-inexact-milliseconds))
(define rows (registry-minifilters))
(define elapsed (- (current-inexact-milliseconds) started))

(if (not (eq? (system-type 'os) 'windows))
    (check-equal? rows '())
    (let ([names (map (lambda (r) (hash-ref r 'name)) rows)])
      (check-true (pair? rows))
      ;; The whole point of the API path: no multi-second walk.
      (check-true (< elapsed 5000) (format "enumeration took ~a ms" elapsed))
      (check-equal? names (remove-duplicates names) "names are unique")
      (check-equal? names (sort names string<?) "sorted by name")
      ;; Inbox filters from both halves of the alphabet: the truncated
      ;; reg.exe listing ended before storqosflt/WdFilter/Wof.
      (for ([inbox (in-list '("FileInfo" "Wof" "WdFilter"))])
        (check-true (and (member inbox names) #t) (format "~a missing" inbox)))
      (for ([row (in-list rows)])
        (check-true (non-empty-string? (hash-ref row 'name)))
        (check-true (and (pair? (hash-ref row 'altitudes))
                         (andmap non-empty-string? (hash-ref row 'altitudes))))
        (check-true (or (not (hash-ref row 'group)) (string? (hash-ref row 'group))))
        (check-true (or (not (hash-ref row 'start))
                        (exact-nonnegative-integer? (hash-ref row 'start))))
        ;; vendors may pad the Group value ("FSFilter Encryption "); the
        ;; row must not carry that padding into group comparisons
        (check-false (and (hash-ref row 'group)
                          (regexp-match? #px"^\\s|\\s$" (hash-ref row 'group)))))))
