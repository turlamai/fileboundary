#lang racket/base
;; Rebuilds the xref-stream test section in tests/decrypt-test.rkt with
;; reader-verified parens. Run from the repo root:
;;   racket tools/.rewrite-xs-test.rkt
(require racket/file racket/list racket/string)

(define p "D:/Codes/fileboundary/tests/decrypt-test.rkt")
(define lines (file->lines p))
(define start (index-where lines (lambda (l) (string-prefix? l ";; ---------- xref-stream PDFs"))))
(define end (index-where lines (lambda (l) (string-contains? l "(define wrong-wrapped "))))

(define section
  (list
   ";; ---------- xref-stream PDFs: object salvage rebuild ----------"
   ""
   ";; a PDF 1.5+ document whose cross-reference table is an xref stream"
   ";; (no classic xref keyword table anywhere) - the layout family the"
   ";; classic head rebuild cannot handle. Objects are laid out so the"
   ";; page objects sit WELL past the 512-byte overwrite zone (like real"
   ";; documents); offsets are computed from actual assembly."
   "(define (make-xref-stream-pdf)"
   "  (define header #\"%PDF-1.7\\n\")"
   "  (define o1"
   "    (string->bytes/utf-8 \"1 0 obj\\n<< /Type /Catalog /Pages 2 0 R >>\\nendobj\\n\"))"
   "  (define o2"
   "    (string->bytes/utf-8"
   "     \"2 0 obj\\n<< /Type /Pages /Kids[3 0 R] /Count 1 /MediaBox[0 0 595 842] >>\\nendobj\\n\"))"
   "  (define filler"
   "    (string->bytes/utf-8"
   "     (format \"5 0 obj\\n<< /Length ~a >>\\nstream\\n~a\\nendstream\\nendobj\\n\""
   "             600 (make-string 600 (integer->char 35)))))"
   "  (define o3"
   "    (string->bytes/utf-8 \"3 0 obj\\n<< /Type /Page /Parent 2 0 R /Contents 4 0 R >>\\nendobj\\n\"))"
   "  (define o4"
   "    (string->bytes/utf-8"
   "     \"4 0 obj\\n<< /Length 42 >>\\nstream\\nBT /F1 24 Tf 72 720 Td (xref-stream) Tj ET\\nendstream\\nendobj\\n\"))"
   "  (define o3-off (+ (bytes-length header) (bytes-length o1)"
   "                    (bytes-length o2) (bytes-length filler)))"
   "  (define o4-off (+ o3-off (bytes-length o3)))"
   "  (define xref-obj-off (+ o4-off (bytes-length o4)))"
   "  (define xref-entries"
   "    (apply bytes-append"
   "           (for/list ((pair (in-list (list (cons 1 (bytes-length header))"
   "                                           (cons 2 (+ (bytes-length header)"
   "                                                      (bytes-length o1))))"
   "                                           (cons 5 o3-off)"
   "                                           (cons 3 o3-off)"
   "                                           (cons 4 o4-off)"
   "                                           (cons 7 xref-obj-off)))))"
   "             (bytes-append (bytes 1)"
   "                           (integer->integer-bytes (cdr pair) 4 #f)"
   "                           (integer->integer-bytes 0 2 #f)))))"
   "  (define xref-obj"
   "    (bytes-append (string->bytes/utf-8"
   "                   (format \"7 0 obj\\n<< /Type /XRef /W [1 4 2] /Root 1 0 R /Length ~a >>\\nstream\\n\""
   "                           (bytes-length xref-entries)))"
   "                  xref-entries"
   "                  (string->bytes/utf-8 \"\\nendstream\\nendobj\\n\")))"
   "  (define startxref-off xref-obj-off)"
   "  (bytes-append header o1 o2 filler o3 o4 xref-obj"
   "                (string->bytes/utf-8"
   "                 (format \"startxref\\n~a\\n%%EOF\\n\" startxref-off)))))"
   ""
   "(define xs-plain"
   "  ;; real wrapped PDFs are far longer than the 512-byte header zone;"
   "  ;; pad the synthetic doc with a PDF comment so the layout matches"
   "  (let ((base (make-xref-stream-pdf)))"
   "    (if (>= (bytes-length base) 600)"
   "        base"
   "        (bytes-append base"
   "                      (string->bytes/utf-8"
   "                       (string-append"
   "                        \"% padding \""
   "                        (make-string (- 600 (bytes-length base)) (integer->char 35))"
   "                        \"\\n\"))))))"
   ";; the real wrapper keeps a PLAINTEXT 512-byte header zone (E-SafeNet"
   ";; magic + vendor markers) and encrypts everything from 512 on"
   "(define wrapper-header"
   "  (bytes-append (bytes 98 20 35 101 155 0 101 1)"
   "                #\"E-SafeNet LOCK wrapper header zone\""
   "                (make-bytes (- 512 8 34) 65)))"
   "(define (wrap-pdf plain xor-pad)"
   "  (define out (make-bytes (bytes-length plain)))"
   "  (for ((o (in-range 512 (bytes-length plain))))"
   "    (bytes-set! out o"
   "                (bitwise-xor (bytes-ref plain o)"
   "                             (hash-ref xor-pad (modulo o 512))))))"
   "  (bytes-append wrapper-header (subbytes out 512)))"
   "(define xs-wrapped (wrap-pdf xs-plain pad))"
   "(define xs-out (make-temporary-file \"fb-xs~a.pdf\"))"
   "(define xs-wrapped-file (make-temporary-file \"fb-xs-wrap~a.bin\"))"
   "(call-with-output-file xs-wrapped-file"
   "  (lambda (out) (write-bytes xs-wrapped out)) #:exists 'replace)"
   "(define xs-report (decrypt-file xs-wrapped-file xs-out pad-path))"
   "(check-equal? (hash-ref xs-report 'kind) \"pdf\")"
   "(check-equal? (hash-ref xs-report 'pages) 1)"
   "(check-equal? (hash-ref xs-report 'xrefBad) 0)"
   ";; the rebuilt document uses a classic xref table again"
   "(define xs-out-bytes (file->bytes xs-out))"
   "(check-true (regexp-match? #rx#\"xref\\r\\n0 \" xs-out-bytes))"
   "(check-true (regexp-match? #rx#\"%%EOF\" xs-out-bytes))"
   ";; the salvaged page content survived"
   "(check-true (regexp-match? #rx#\"xref-stream\" xs-out-bytes))"
   "(check-false (regexp-match? #rx#\"startxref\" xs-out-bytes))"
   ""
   ";; ---------- pad mismatch is reported as such ----------"
   ""
   ";; wrap with a rotated pad: decrypt must fail with a pad-specific"
   ";; diagnostic, not a misleading structural message"
   "(define wrong-pad"
   "  (for/hash ((c (in-range 512)))"
   "    (values c (hash-ref pad (modulo (+ c 17) 512)))))"
   "(define wrong-wrapped (wrap-pdf xs-plain wrong-pad))"
   "(define wrong-wrapped-file (make-temporary-file \"fb-mismatch~a.bin\"))"
   "(call-with-output-file wrong-wrapped-file"
   "  (lambda (out) (write-bytes wrong-wrapped out)) #:exists 'replace)"
   "(check-exn"
   " #rx\"does not match this file\""
   " (lambda ()"
   "   (decrypt-file wrong-wrapped-file"
   "                 (make-temporary-file \"fb-mismatch~a.pdf\")"
   "                 pad-path)))"))

;; reader-validate: the section must parse as a sequence of forms
(define sp (open-input-string (string-join section "\n")))
(port-count-lines! sp)
(with-handlers ((exn:fail? (lambda (e)
                             (printf "SECTION READ FAIL: ~a\n" (exn-message e))
                             (exit 1))))
  (let loop ()
    (define x (read sp))
    (unless (eof-object? x) (loop))))
(printf "section parses clean (~a lines)\n" (length section))

(define rebuilt
  (append (take lines start) section (drop lines end)))
(with-output-to-file p
  (lambda () (display (string-join rebuilt "\n")))
  #:exists 'replace)
(printf "rewrote section: lines ~a..~a -> ~a lines\n" (add1 start) end (length section))
