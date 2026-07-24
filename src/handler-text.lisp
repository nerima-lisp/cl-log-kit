;;;; src/handler-text.lisp
;;;
;;; text-handler wire format: one physical line per record shaped as
;;; ts=... level=... logger="..." msg="..." field."k"="v", with every
;;; untrusted token escaped so a log line can never be spoofed or split.
(in-package #:log-kit)

;;; FLOAT-INFINITY-P / FLOAT-NAN-P decode a float's raw bit pattern (exponent
;;; and mantissa fields); they never perform a trapping floating-point
;;; operation, so unlike arithmetic on a non-finite float, calling them here
;;; cannot itself signal ARITHMETIC-ERROR.
(defun %safe-text-finite-number-p (value)
  (or (not (floatp value))
      (not (or (sb-ext:float-infinity-p value) (sb-ext:float-nan-p value)))))

(defun %safe-text-value-string (value)
  (typecase value
    (string value)
    (character (string value))
    (integer (format nil "~D" value))
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
    (symbol (if (keywordp value) (string-downcase (symbol-name value)) (symbol-name value)))
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
  (loop for character across (%safe-text-value-string value)
        for code = (char-code character)
        do (cond
             ((char= character #\\) (write-string "\\\\" stream))
             ((char= character #\") (write-string "\\\"" stream))
             ((char= character #\Newline) (write-string "\\n" stream))
             ((char= character #\Return) (write-string "\\r" stream))
             ((char= character #\Tab) (write-string "\\t" stream))
             ((or (< code 32) (= code 127) (= code #x2028) (= code #x2029)
                  (<= #xD800 code #xDFFF) (%text-spoof-character-p code))
              (%write-unicode-escape code stream))
             (t (write-char character stream)))))

(defun %write-text-record (record output)
  (format output "ts=~D level=~A logger=\"" (log-record-timestamp record)
          (level-name (log-record-level record)))
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
  (%write-handler-record handler (lambda (stream) (%write-text-record record stream))))
