#lang racket/base
;; Drop-handler thread contract for the native WinUI host.
;;
;; The GUI has no unit-test layer, so this locks the one invariant the
;; crash reports violated: the XAML Drop handler awaits an async read that
;; resumes on a threadpool thread, and every XAML object it touches (the
;; drop deferral, the sender TextBox, the window) is apartment-bound to the
;; UI thread. Calling any of them after the await - outside a
;; DispatcherQueue::TryEnqueue lambda - raises RPC_E_WRONG_THREAD, fails the
;; process fast mid-drop and leaves the shell's drag image on screen.
;;
;; The check is structural on purpose: it is the only automated evidence
;; available for a native GUI, and it fails on exactly the shape that
;; shipped the crash (deferral.Complete() after the co_await at function
;; body level).

(require rackunit
         racket/file
         racket/list
         racket/string)

(define cpp-path "../windows/MainWindow.xaml.cpp")
(define xaml-path "../windows/MainWindow.xaml")

(define cpp (file->string cpp-path))
(define xaml (file->string xaml-path))
(define lines (string-split cpp "\n"))

;; ---- both drop channels must stay wired -------------------------------

;; Explorer drops reach the top-level HWND through WM_DROPFILES; that is the
;; primary, synchronous, UI-thread-only path.
(check-true (string-contains? cpp "DragAcceptFiles(hwnd, TRUE)")
            "the Win32 WM_DROPFILES channel must stay registered")
(check-true (string-contains? cpp "SetWindowSubclass(hwnd, FileDropSubclassProc")
            "the WM_DROPFILES subclass must stay installed")
;; The XAML channel is the fallback for hosts where OLE reaches the island,
;; and it provides the copy cursor feedback.
(check-true (string-contains? cpp "DropEvent()"))
(check-false (null? (regexp-match* #rx"AllowDrop=\"True\"" xaml))
             "path boxes must keep accepting drops")

;; ---- the XAML Drop handler must stay on the UI thread -------------------

(define start
  (for/first ([line lines] [i (in-naturals)]
              #:when (string-contains? line "fire_and_forget DropFileIntoBox("))
    i))
(check-true (and start (exact-nonnegative-integer? start))
            "DropFileIntoBox must exist")

(define body
  (let loop ([i (add1 start)] [acc '()])
    (define line (list-ref lines i))
    (if (string-prefix? line "}")
        (reverse acc)
        (loop (add1 i) (cons line acc)))))

(define await-line
  (for/first ([line (in-list body)] #:when (string-contains? line "co_await"))
    line))
(check-true (and await-line (string? await-line))
            "the handler still awaits the storage-item read (async by design)")

;; Calls that may only run on the UI thread.
(define ui-only
  (list #rx"deferral\\.Complete\\(\\)"
        #rx"box\\.Text\\("
        #rx"ShowTextResult\\("
        #rx"FillDecryptOutput\\("
        #rx"SyncDecryptOutput\\("
        #rx"try_as<"))

(define (brace-delta line)
  (- (count (lambda (c) (char=? c #\{)) (string->list line))
     (count (lambda (c) (char=? c #\})) (string->list line))))

(define complete-count 0)

(for ([line (in-list body)] [i (in-naturals)])
  (when (regexp-match? #rx"deferral\\.Complete\\(\\)" line)
    (set! complete-count (add1 complete-count)))
  (for ([rx (in-list (filter (lambda (rx) (regexp-match? rx line)) ui-only))])
    (define header
      (for/first ([j (in-range (sub1 i) -1 -1)]
                  #:when (string-contains? (list-ref body j) "TryEnqueue("))
        j))
    (check-true (and header (exact-nonnegative-integer? header))
                (format "line ~a touches a UI-thread-only object outside a DispatcherQueue::TryEnqueue lambda: ~a"
                        (add1 (+ start i))
                        (string-trim line)))
    (when header
      (define depth
        (for/sum ([j (in-range header (add1 i))])
          (brace-delta (list-ref body j))))
      (check-true (> depth 0)
                  (format "line ~a is not inside the TryEnqueue lambda opened at line ~a"
                          (add1 (+ start i))
                          (add1 (+ start header)))))))

(check-true (> complete-count 0)
            "the drop deferral must still be completed (or the OLE drop session hangs)")

;; ---- coroutine parameters must not be references -----------------------
;;
;; A reference parameter only lives as long as the caller's frame. The XAML
;; Drop handler returns as soon as the handler hits its first suspension, so
;; any `T const&` parameter is a dangling reference when the continuation
;; runs - copying it (e.g. into the TryEnqueue lambda) AddRefs a dead stack
;; slot and crashes with an access violation in IUnknown::add_ref. Parameters
;; that are still used after the await must be passed by value so that the
;; coroutine frame owns a copy.
(define signature-lines
  (let loop ([i start] [acc '()])
    (define line (list-ref lines i))
    (if (string-suffix? line "{")
        (reverse (cons line acc))
        (loop (add1 i) (cons line acc)))))
(define signature (string-join signature-lines " "))
(check-false (regexp-match? #rx"&" signature)
             (format "DropFileIntoBox must not take reference parameters (they dangle across the co_await): ~a"
                     (string-trim signature)))

;; ---- the generated decrypt output must follow its input ---------------
;;
;; The output path generated from the encrypted input belongs to that input.
;; It is regenerated on every change of the input box - typed, dropped, or
;; picked - so clearing the input clears the output with it, while an output
;; path the operator typed is kept.
(check-true (string-contains? cpp "DecryptInputBox().TextChanged(")
            "the decrypt input must re-sync the generated output on every change")
(check-true (string-contains? cpp "output_box.Text() == auto_value")
            "a generated output is replaced, an operator edit is kept")
(check-true (string-contains? cpp "DecryptOutputBox(), decrypt_auto_output_)")
            "the sync must track the last generated output")
