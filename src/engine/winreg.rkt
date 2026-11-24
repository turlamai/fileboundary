#lang racket/base

;; Read-only enumeration of registered filesystem minifilters through the
;; advapi32 registry API: no child process, no timeout, no code-page
;; decoding. `reg query Services /s /f Altitude` walks every subkey of the
;; Services tree (10+ s on a developer machine) and was killed by the 8 s
;; diagnostic budget, which silently dropped the second half of the
;; alphabet - including the transparent-encryption filter the operator was
;; looking for. Opening only Services\<svc>\Instances\<inst> takes ~40 ms.
;;
;; Windows only; any other platform yields the empty list.
(require ffi/unsafe
         ffi/unsafe/define
         racket/list
         racket/string
         "win-text.rkt")

(provide registry-minifilters)

(define-ffi-definer define-advapi32 (ffi-lib "advapi32"))

(define ERROR_SUCCESS 0)
(define KEY_READ #x20019)
(define REG_SZ 1)
(define REG_DWORD 4)
;; Predefined HKEY handles are integer constants, not pointers; ptr-add
;; with a #f base turns the integer into a pointer value.
(define HKEY_LOCAL_MACHINE (ptr-add #f #x80000002))

(define-advapi32 RegOpenKeyExW
  (_fun _pointer _string/utf-16 _uint32 _uint32 (hkey : (_ptr o _pointer))
        -> (r : _int32) -> (values r hkey)))
(define-advapi32 RegCloseKey (_fun _pointer -> _int32))
(define-advapi32 RegEnumKeyExW
  (_fun _pointer _uint32
        _pointer (name-len : _pointer)
        _pointer _pointer _pointer _pointer
        -> _int32))
(define-advapi32 RegQueryValueExW
  (_fun _pointer _string/utf-16 _pointer _pointer _pointer _pointer
        -> _int32))

(define services-key-path "SYSTEM\\CurrentControlSet\\Services")

;; Names of the subkeys of an open key, in enumeration order.
(define (subkey-names hkey)
  (define len (malloc 4 'raw))
  (define buffer (malloc 512 'raw))  ; 256 UTF-16 code units
  (let loop ([index 0] [acc '()])
    (ptr-set! len _uint32 0 256)
    (define r (RegEnumKeyExW hkey index buffer len #f #f #f #f))
    (if (not (= r ERROR_SUCCESS))
        (reverse acc)
        (let* ([units (ptr-ref len _uint32)]
               [name (utf16le->string (pointer->bytes buffer (* 2 units)))])
          (loop (add1 index) (cons name acc))))))

;; One value of an open key as (cons type bytes), or #f when absent.
(define (query-value hkey name)
  (define type (malloc 4 'raw))
  (define size (malloc 4 'raw))
  (ptr-set! size _uint32 0 0)
  (define r (RegQueryValueExW hkey name #f type #f size))
  (and (or (= r ERROR_SUCCESS) (= r 234))  ; 234 = ERROR_MORE_DATA
       (let ([n (ptr-ref size _uint32)])
         (and (> n 0)
              (let ([data (malloc n 'raw)])
                (and (= (RegQueryValueExW hkey name #f type data size) ERROR_SUCCESS)
                     (cons (ptr-ref type _uint32)
                           (pointer->bytes data (ptr-ref size _uint32)))))))))

(define (value->string v)
  ;; Some vendors pad their Group value ("FSFilter Encryption "); trim so
  ;; group comparisons never miss on whitespace.
  (and v (= (car v) REG_SZ) (string-trim (utf16le->string (cdr v)))))

(define (value->integer v)
  (and v (= (car v) REG_DWORD)
       (integer-bytes->integer (subbytes (cdr v) 0 4) #f #f)))

;; Open `path` under HKLM read-only for the dynamic extent of (proc hkey);
;; #f when the key does not exist or cannot be read.
(define (with-key path proc)
  (define-values (r hkey) (RegOpenKeyExW HKEY_LOCAL_MACHINE path 0 KEY_READ))
  (if (= r ERROR_SUCCESS)
      (dynamic-wind void
                    (lambda () (proc hkey))
                    (lambda () (RegCloseKey hkey)))
      #f))

(define (service-filter svc)
  (define base (string-append services-key-path "\\" svc))
  (with-key base
            (lambda (hkey)
              (define group (value->string (query-value hkey "Group")))
              (define start (value->integer (query-value hkey "Start")))
              (define altitudes
                (or (with-key (string-append base "\\Instances")
                              (lambda (instances)
                                (filter values
                                        (for/list ([inst (in-list (subkey-names instances))])
                                          (with-key (string-append base "\\Instances\\" inst)
                                                    (lambda (ihkey)
                                                      (value->string (query-value ihkey "Altitude"))))))))
                    '()))
              (and (pair? altitudes)
                   (hash 'name svc
                         'altitudes (remove-duplicates altitudes)
                         'group group
                         'start start)))))

;; -> (listof (hash name altitudes group start)) sorted by name; every
;; service that carries at least one Instances\<inst>\Altitude value.
;; `group` is the service's Group (e.g. "FSFilter Encryption") and `start`
;; its Start type (1 = loaded at boot), both #f when absent.
(define (registry-minifilters)
  (cond
    [(not (eq? (system-type 'os) 'windows)) '()]
    [else
     (or (with-key services-key-path
                    (lambda (services)
                      (sort (filter-map service-filter (subkey-names services))
                            string<? #:key (lambda (h) (hash-ref h 'name)))))
         '())]))
