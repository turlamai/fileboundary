#lang racket/base

;; Windows child-process control for GUI hosts. A GUI process has no
;; console; the OS allocates one for every console-subsystem child
;; (fltmc, driverquery, tasklist, curl, ...) and a black window flashes
;; over the app. Everything here launches via CreateProcessW with
;; CREATE_NO_WINDOW; capture variants run through `cmd /c` file
;; redirection (cmd opens the redirect targets itself — no handle
;; inheritance involved). The kernel32 FFI lives in the `ffi-impl`
;; submodule and only instantiates on Windows (local-require at call
;; time), so loading this module on POSIX stays side-effect free.
;; POSIX callers keep a plain subprocess pipeline with the same
;; return shape.

(require racket/file
         racket/format
         racket/port
         racket/string
         racket/system)

(provide has-console?
         windows-quote-arg
         run-child*/exit-code
         run-hidden-capture)

;; MSVCRT argv quoting: quote when empty / whitespace / a quote is
;; present; double backslashes that precede a quote or the end of a
;; quoted argument, so the trailing run survives the closing quote.
;; Pure string logic (no FFI) so it is testable on every platform.
(define (windows-quote-arg a)
  (define n (string-length a))
  (cond [(zero? n) "\"\""]
        [(and (not (string-contains? a " "))
              (not (string-contains? a "\t"))
              (not (string-contains? a "\"")))
         a]
        [else
         (define out (open-output-string))
         (display #\" out)
         (let loop ([bs 0] [i 0])
           (cond [(= i n)
                  (for ([_ (in-range (* 2 bs))]) (display #\\ out))
                  (display #\" out)]
                 [else
                  (define c (string-ref a i))
                  (cond [(char=? c #\\) (loop (+ bs 1) (+ i 1))]
                        [(char=? c #\")
                         (for ([_ (in-range (+ (* 2 bs) 1))]) (display #\\ out))
                         (display #\" out)
                         (loop 0 (+ i 1))]
                        [else
                         (for ([_ bs]) (display #\\ out))
                         (display c out)
                         (loop 0 (+ i 1))])]))
         (get-output-string out)]))

;; POSIX twin of the FFI capture: subprocess with pipes, concurrent
;; drain, soft timeout. Same (values code out err timed-out?) shape.
(define (posix-capture exe argv timeout-seconds)
  (define out-val (box #""))
  (define err-val (box #""))
  (define timed-out? #f)
  (define-values (proc stdout stdin stderr)
    (apply subprocess #f #f #f exe argv))
  (close-output-port stdin)
  (define out-worker (thread (lambda () (set-box! out-val (read-all stdout)))))
  (define err-worker (thread (lambda () (set-box! err-val (read-all stderr)))))
  (define finished? (sync/timeout timeout-seconds proc))
  (unless finished?
    (set! timed-out? #t)
    (subprocess-kill proc #t))
  (subprocess-wait proc)
  (for ([w (in-list (list out-worker err-worker))]
        [p (in-list (list stdout stderr))])
    (unless (sync/timeout 2 w)
      (close-input-port p)
      (kill-thread w)))
  (unless (port-closed? stdout) (close-input-port stdout))
  (unless (port-closed? stderr) (close-input-port stderr))
  (values (if finished? (subprocess-status proc) 'null)
          (bytes->string/latin-1 (unbox out-val))
          (bytes->string/latin-1 (unbox err-val))
          timed-out?))

(define (read-all input)
  (define collected (open-output-bytes))
  (let loop ()
    (define chunk (read-bytes 4096 input))
    (unless (eof-object? chunk)
      (write-bytes chunk collected)
      (loop)))
  (get-output-bytes collected))

(module ffi-impl racket/base
  (require ffi/unsafe
           ffi/unsafe/define
           racket/file
           racket/string)
  (provide has-console?
           run-hidden*/exit-code
           run-hidden-capture)

  ;; Submodules cannot see the parent's definitions; the quoting rules
  ;; live here too (kept in sync with the parent copy, which exists for
  ;; cross-platform testing).
  (define (windows-quote-arg a)
    (define n (string-length a))
    (cond [(zero? n) "\"\""]
          [(and (not (string-contains? a " "))
                (not (string-contains? a "\t"))
                (not (string-contains? a "\"")))
           a]
          [else
           (define out (open-output-string))
           (display #\" out)
           (let loop ([bs 0] [i 0])
             (cond [(= i n)
                    (for ([_ (in-range (* 2 bs))]) (display #\\ out))
                    (display #\" out)]
                   [else
                    (define c (string-ref a i))
                    (cond [(char=? c #\\) (loop (+ bs 1) (+ i 1))]
                          [(char=? c #\")
                           (for ([_ (in-range (+ (* 2 bs) 1))]) (display #\\ out))
                           (display #\" out)
                           (loop 0 (+ i 1))]
                          [else
                           (for ([_ bs]) (display #\\ out))
                           (display c out)
                           (loop 0 (+ i 1))])]))
           (get-output-string out)]))

  (define CREATE_NO_WINDOW #x08000000)
  (define WAIT_OBJECT_0 0)
  (define WAIT_TIMEOUT #x00000102)
  ;; STARTUPINFOW, x64: cb + 3 ptrs + 8 DWORDs + 2 WORDs + pad + 3
  ;; handles = 96 bytes.
  (define STARTUPINFOW-SIZE 96)

  (define-ffi-definer define-kernel32 (ffi-lib "kernel32"))

  (define-kernel32 GetConsoleWindow (_fun -> _pointer))

  (define (has-console?)
    (not (ptr-equal? (GetConsoleWindow) #f)))

  (define-kernel32 CreateProcessW
    (_fun _string/utf-16 ; lpApplicationName (unquoted, exact path)
          _string/utf-16 ; lpCommandLine
          _pointer ; lpProcessAttributes
          _pointer ; lpThreadAttributes
          _bool ; bInheritHandles
          _uint32 ; dwCreationFlags
          _pointer ; lpEnvironment
          _pointer ; lpCurrentDirectory
          (si : _bytes)
          (pi : (_ptr o (_list-struct _pointer _pointer _uint32 _uint32)))
          -> (ok : _bool)
          -> (values ok pi)))

  (define-kernel32 WaitForSingleObject
    (_fun _pointer _uint32 -> _uint32)) ; ms

  (define-kernel32 GetExitCodeProcess
    (_fun _pointer (code : (_ptr o _uint32)) -> (ok : _bool)
          -> (if ok code (error 'winproc "GetExitCodeProcess failed"))))

  (define-kernel32 CloseHandle
    (_fun _pointer -> _void))

  (define-kernel32 TerminateProcess
    (_fun _pointer _uint32 -> _bool))

  (define-kernel32 GetLastError
    (_fun -> _uint32))

  (define (launch exe-str cmdline creation-flags si)
    (define-values (ok pi)
      (CreateProcessW exe-str cmdline #f #f #f
                      creation-flags #f #f si))
    (unless ok
      (error 'winproc "CreateProcessW failed (~a): ~a"
             (GetLastError) cmdline))
    pi)

  ;; timeout-seconds #f means wait forever
  (define (finish hProcess timeout-seconds)
    (define wait
      (if timeout-seconds
          (WaitForSingleObject hProcess (* 1000 timeout-seconds))
          (WaitForSingleObject hProcess #xFFFFFFFF)))
    (define timed-out? (= wait WAIT_TIMEOUT))
    (when timed-out?
      (TerminateProcess hProcess 1)
      (WaitForSingleObject hProcess #xFFFFFFFF))
    (define code (GetExitCodeProcess hProcess))
    (CloseHandle hProcess)
    (values code timed-out?))

  ;; The parent owns argv semantics: exe path (backslashes — cmd and
  ;; console tools reject forward-slash paths) becomes argv[0], then
  ;; the quoted arguments.
  (define (windows-cmdline exe args)
    (define exe-str
      (regexp-replace* #rx"/"
                       (path->string (path->complete-path exe)) "\\"))
    (values exe-str
            (string-join
             (cons (windows-quote-arg exe-str)
                   (for/list ([a (in-list args)])
                     (windows-quote-arg (if (path? a) (path->string a) a))))
             " ")))

  (define (run-hidden*/exit-code exe args)
    (define-values (exe-str cmdline) (windows-cmdline exe args))
    (define si (make-bytes STARTUPINFOW-SIZE))
    (integer->integer-bytes STARTUPINFOW-SIZE 4 #f #t si 0)
    (define pi (launch exe-str cmdline CREATE_NO_WINDOW si))
    (define hProcess (list-ref pi 0))
    (define hThread (list-ref pi 1))
    (CloseHandle hThread)
    (define-values (code _timed-out?) (finish hProcess #f))
    code)

  ;; Capture via cmd /c file redirection: cmd opens the redirect
  ;; targets itself, so no handle inheritance is involved and the
  ;; console-less child still writes to files the parent can read.
  ;; cmd /c takes the quoted exe as the command itself, so NO argv[0]
  ;; copy here (windows-cmdline's duplicate would become argument 1).
  ;; cmd /c strips the outer quote pair; the inner quoted exe path and
  ;; quoted redirect targets survive. Returns (values exit-code stdout
  ;; stderr timed-out?).
  (define (run-hidden-capture exe argv timeout-seconds)
    (define exe-str
      (regexp-replace* #rx"/"
                       (path->string (path->complete-path exe)) "\\"))
    (define out-tmp (make-temporary-file "fb-cap~a.out"))
    (define err-tmp (make-temporary-file "fb-cap~a.err"))
    (define inner
      (string-join
       (for/list ([a (in-list argv)])
         (windows-quote-arg (if (path? a) (path->string a) a)))
       " "))
    (define wrapped
      (format "cmd.exe /c \"\"~a\" ~a > \"~a\" 2> \"~a\"\""
              exe-str inner (path->string out-tmp) (path->string err-tmp)))
    (define si (make-bytes STARTUPINFOW-SIZE))
    (integer->integer-bytes STARTUPINFOW-SIZE 4 #f #t si 0)
    (with-handlers ([exn:fail?
                     (lambda (_)
                       (values 'null "" "" #f))])
      (define pi
        (launch "C:/Windows/System32/cmd.exe" wrapped CREATE_NO_WINDOW si))
      (define hProcess (list-ref pi 0))
      (define hThread (list-ref pi 1))
      (CloseHandle hThread)
      (define-values (code timed-out?) (finish hProcess timeout-seconds))
      (define out (with-handlers ([exn:fail? (lambda _ #"")])
                    (file->bytes out-tmp)))
      (define err (with-handlers ([exn:fail? (lambda _ #"")])
                    (file->bytes err-tmp)))
      (for ([f (in-list (list out-tmp err-tmp))])
        (with-handlers ([exn:fail? void]) (delete-file f)))
      (values code
              (bytes->string/latin-1 out)
              (bytes->string/latin-1 err)
              timed-out?))))

;; Unified entry points. Windows GUI hosts go through the FFI path;
;; Windows console processes (the CLI) keep the plain system* path so
;; child stderr stays attached to the caller's console; POSIX keeps
;; plain subprocess semantics. The submodule only instantiates lazily,
;; at first call on Windows.
(define (run-child*/exit-code exe args)
  (case (system-type)
    [(windows)
     (let ()
       (local-require (only-in (submod "." ffi-impl)
                               run-hidden*/exit-code has-console?))
       (if (has-console?)
           (apply system*/exit-code exe args)
           (run-hidden*/exit-code exe args)))]
    [else (apply system*/exit-code exe args)]))

;; Capture variant for diagnostics: (values code stdout stderr
;; timed-out?). On Windows every host goes through the FFI path —
;; console hosts lose the child's console attachment, which is fine
;; for bounded diagnostic commands.
(define (run-hidden-capture exe argv timeout-seconds)
  (case (system-type)
    [(windows)
     (let ()
       (local-require (only-in (submod "." ffi-impl) run-hidden-capture))
       (run-hidden-capture exe argv timeout-seconds))]
    [else (posix-capture exe argv timeout-seconds)]))

;; Diagnostic probe for callers that branch on console availability.
(define (has-console?)
  (case (system-type)
    [(windows)
     (let ()
       (local-require (only-in (submod "." ffi-impl) has-console?))
       (has-console?))]
    [else #t]))
