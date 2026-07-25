;;;; src/handler-text.lisp
;;;
;;; text-handler wire format: one physical line per record shaped as
;;; ts=... level=... logger="..." msg="..." field."k"="v", with every
;;; untrusted token escaped so a log line can never be spoofed or split.
(in-package #:log-kit)

;;; This file's hot path runs on every enabled log call. SAFETY 1 (not 0)
;;; keeps ordinary type checking — including the resource-limit guards
;;; elsewhere in the library that depend on catchable type/range errors —
;;; while SPEED 3 lets SBCL apply the same optimizations a caller would get
;;; from per-function (OPTIMIZE ...) declarations, without repeating them
;;; on every DEFUN in the file.
(declaim (optimize (speed 3) (safety 1) (compilation-speed 0)))

;;; FLOAT-INFINITY-P / FLOAT-NAN-P decode a float's raw bit pattern (exponent
;;; and mantissa fields); they never perform a trapping floating-point
;;; operation, so unlike arithmetic on a non-finite float, calling them here
;;; cannot itself signal ARITHMETIC-ERROR.
(defun %safe-text-finite-number-p (value)
  (or (not (floatp value))
      (not (or (sb-ext:float-infinity-p value) (sb-ext:float-nan-p value)))))

(defun %safe-text-value-string (value)
  "Render VALUE for a caller that has already special-cased plain integers
(their decimal digits can never need escaping, so %WRITE-TEXT-VALUE writes
them directly and never reaches this function for an INTEGER)."
  (typecase value
    (string value)
    (character (string value))
    (float (if (%safe-text-finite-number-p value)
               (format nil "~G" value)
               "<non-finite-float>"))
    (ratio (format nil "~A/~A" (numerator value) (denominator value)))
    (complex
     (if (and (%safe-text-finite-number-p (realpart value))
              (%safe-text-finite-number-p (imagpart value)))
         (format nil "(~A ~:[-~;+~] ~Ai)" (realpart value) (minusp (imagpart value))
                 (abs (imagpart value)))
         "<non-finite-complex>"))
    (symbol (%symbol-field-string value))
    (t "#<object>")))

(defun %text-spoof-character-p (code)
  "True for zero-width, bidi-control, and BOM code points that could make a
rendered log line look different from what it actually contains."
  (or (<= #x200B code #x200F)
      (<= #x202A code #x202E)
      (<= #x2060 code #x2064)
      (<= #x2066 code #x2069)
      (= code #xFEFF)))

(defun %write-text-value (value stream)
  ;; An integer's decimal digits and optional leading minus sign can never
  ;; contain an escape-worthy character, so writing it directly skips both
  ;; %SAFE-TEXT-VALUE-STRING's intermediate string and the run-scanning
  ;; loop below entirely — the common case for numeric fields.
  (if (integerp value)
      (%write-integer value stream)
      (let* ((raw (%safe-text-value-string value))
             ;; Guaranteed-simple copy (a no-op for the already-simple string
             ;; %SAFE-TEXT-VALUE-STRING returns) so SCHAR and the run-flushing
             ;; WRITE-STRING take the fast simple-array path instead of the
             ;; generic hairy-array element reader.
             (text (if (simple-string-p raw) raw (coerce raw 'simple-string)))
             (length (length text))
             (run-start 0))
        (declare (type simple-string text) (type fixnum length run-start))
        (flet ((flush-run (end)
                 (declare (type fixnum end))
                 (when (< run-start end)
                   (write-string text stream :start run-start :end end))))
          (dotimes (index length)
            (declare (type fixnum index))
            (let ((character (schar text index)))
              ;; Fast path: a printable ASCII character (code 32..126) needs
              ;; escaping only if it is a quote or backslash. Everything else
              ;; in that range — every letter, digit, space, and ordinary
              ;; punctuation, i.e. the overwhelming majority of log text —
              ;; stays part of the current run with a single range test and
              ;; two character comparisons, never touching CHAR-CODE or the
              ;; five-range spoof-character scan. Only the rare non-printable
              ;; or non-ASCII character pays for the full classification.
              (cond
                ((char<= #\Space character #\~)
                 (case character
                   (#\" (flush-run index) (write-string "\\\"" stream) (setf run-start (1+ index)))
                   (#\\ (flush-run index) (write-string "\\\\" stream) (setf run-start (1+ index)))))
                (t
                 (let ((code (char-code character)))
                   (declare (type fixnum code))
                   (cond
                     ((char= character #\Newline)
                      (flush-run index) (write-string "\\n" stream) (setf run-start (1+ index)))
                     ((char= character #\Return)
                      (flush-run index) (write-string "\\r" stream) (setf run-start (1+ index)))
                     ((char= character #\Tab)
                      (flush-run index) (write-string "\\t" stream) (setf run-start (1+ index)))
                     ((or (< code 32) (= code 127) (= code #x2028) (= code #x2029)
                          (<= #xD800 code #xDFFF) (%text-spoof-character-p code))
                      (flush-run index) (%write-unicode-escape code stream) (setf run-start (1+ index)))))))))
          (flush-run length)))))

(defun %write-text-record (record output)
  ;; A direct WRITE-STRING/PRINC sequence avoids FORMAT's control-string
  ;; interpretation overhead on this always-executed prefix of every record.
  (write-string "ts=" output)
  (%write-integer (log-record-timestamp record) output)
  (write-string " level=" output)
  (write-string (level-name (log-record-level record)) output)
  (write-string " logger=\"" output)
  (%write-text-value (%log-record-logger-name record) output)
  (write-string "\" msg=\"" output)
  (%write-text-value (%log-record-message record) output)
  (write-char #\" output)
  (dolist (field (%log-record-fields record))
    (write-string " field.\"" output)
    (%write-text-value (car field) output)
    (write-string "\"=\"" output)
    (%write-text-value (cdr field) output)
    (write-char #\" output))
  (write-char #\Newline output))

(defmethod handle-log-record ((handler text-handler) record)
  (check-type record log-record)
  ;; %WRITE-HANDLER-RECORD calls WRITER synchronously and never retains it, so
  ;; the closure — which only captures RECORD — has dynamic extent and SBCL
  ;; stack-allocates it, removing a per-call heap allocation from the hot path.
  (flet ((writer (stream) (%write-text-record record stream)))
    (declare (dynamic-extent #'writer))
    (%write-handler-record handler #'writer)))
