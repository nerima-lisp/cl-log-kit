(in-package #:log-kit)

(declaim (optimize (speed 3) (safety 1) (compilation-speed 0)))

;;; Shared by validation and writing so both paths report the same reason.
(defparameter +unsupported-json-value-reason+
  "supported values are explicit JSON values, strings, integers, finite floats, and symbols")

(defun %json-key-string (key)
  (etypecase key
    (string key)
    ;; Keywords are the common case and their downcased name is interned once
    ;; (see %CACHED-KEYWORD-NAME); only the rare non-keyword symbol pays a
    ;; fresh STRING-DOWNCASE.
    (keyword (%cached-keyword-name key))
    (symbol (string-downcase (symbol-name key)))))

(defun %surrogate-code-point-p (code)
  (<= #xD800 code #xDFFF))

(defun %validate-json-string (value)
  ;; BASE-STRING cannot contain surrogate code points on SBCL.
  (unless (typep value 'base-string)
    ;; Coerce once so the scan can use the simple-string fast path.
    (let ((string (if (simple-string-p value) value (coerce value 'simple-string))))
      (declare (type simple-string string))
      (dotimes (index (length string))
        (declare (type fixnum index))
        (when (%surrogate-code-point-p (char-code (schar string index)))
          (error 'unsupported-json-value :value value
                 :reason "strings must not contain Unicode surrogate code points")))))
  value)

(defun %write-json-string (value stream)
  ;; HANDLE-LOG-RECORD validates the record before calling this writer.
  (write-char #\" stream)
  ;; Use a simple string for the character scan and run writes.
  (let* ((string (if (simple-string-p value) value (coerce value 'simple-string)))
         (length (length string))
         (run-start 0))
    (declare (type simple-string string) (type fixnum length run-start))
    (flet ((flush-run (end)
             (declare (type fixnum end))
             (when (< run-start end)
               (write-string string stream :start run-start :end end))))
      (dotimes (index length)
        (declare (type fixnum index))
        (let ((character (schar string index)))
          ;; Printable ASCII needs escaping only for quotes and backslashes.
          (cond
            ((char<= #\Space character #\~)
             (case character
               (#\" (flush-run index) (write-string "\\\"" stream) (setf run-start (1+ index)))
               (#\\ (flush-run index) (write-string "\\\\" stream) (setf run-start (1+ index)))))
            (t
             (let ((code (char-code character)))
               (declare (type fixnum code))
               (let ((escape (case character
                               (#\Backspace "\\b")
                               (#\Page "\\f")
                               (#\Newline "\\n")
                               (#\Return "\\r")
                               (#\Tab "\\t")
                               (otherwise nil))))
                 (cond
                   (escape
                    (flush-run index) (write-string escape stream) (setf run-start (1+ index)))
                   ((or (< code 32) (= code 127))
                    (flush-run index) (%write-unicode-escape code stream)
                    (setf run-start (1+ index))))))))))
      (flush-run length)))
  (write-char #\" stream))

(defun %finite-float-p (value)
  ;; Decode VALUE's raw exponent/mantissa bits rather than probing with
  ;; arithmetic: the old (- value value) test boxed a fresh double on every
  ;; call (twice per field — once to validate, once to write), while
  ;; FLOAT-INFINITY-P / FLOAT-NAN-P never allocate and never trap. Callers
  ;; only reach here with an actual float.
  (not (or (sb-ext:float-infinity-p value) (sb-ext:float-nan-p value))))

(defun %write-json-float (value stream)
  (unless (%finite-float-p value)
    (error 'unsupported-json-value :value value :reason "JSON numbers must be finite"))
  (if (zerop value)
      (write-string (if (minusp (float-sign value)) "-0.0" "0.0") stream)
      ;; Use the value's float type so SBCL emits an RFC 8259 exponent marker
      ;; directly to STREAM without an intermediate string.
      (let ((*read-default-float-format* (etypecase value
                                           (double-float 'double-float)
                                           (single-float 'single-float))))
        (prin1 value stream))))

(defun %write-json-object (object stream)
  (%write-json-members (%json-object-members object) stream))

(defun %write-json-array (array stream)
  (write-char #\[ stream)
  (loop for element across (%json-array-elements array)
        for first = t then nil
        do (unless first (write-char #\, stream))
           (%write-json-value element stream))
  (write-char #\] stream))

(defun %write-json-value (value stream)
  (cond
    ((or (null value) (json-null-p value)) (write-string "null" stream))
    ((json-false-p value) (write-string "false" stream))
    ((eq value t) (write-string "true" stream))
    ((json-object-p value) (%write-json-object value stream))
    ((json-array-p value) (%write-json-array value stream))
    ((stringp value) (%write-json-string value stream))
    ;; %WRITE-INTEGER emits base-10 digits directly, so it is both faster than
    ;; the printer and immune to a caller-bound *PRINT-BASE* that could
    ;; otherwise produce a non-decimal (invalid-JSON) integer.
    ((integerp value) (%write-integer value stream))
    ((floatp value) (%write-json-float value stream))
    ((symbolp value)
     (%write-json-string (%symbol-field-string value)
                         stream))
    (t (error 'unsupported-json-value :value value
              :reason +unsupported-json-value-reason+))))

(defun %validate-json-value (value)
  (cond
    ((or (null value) (json-null-p value) (json-false-p value) (eq value t) (integerp value)) value)
    ((json-object-p value)
     (dolist (pair (%json-object-members value) value)
       (%validate-json-string (%json-key-string (car pair)))
       (%validate-json-value (cdr pair))))
    ((json-array-p value)
     (loop for element across (%json-array-elements value) do (%validate-json-value element))
     value)
    ((stringp value) (%validate-json-string value))
    ((floatp value)
     (unless (%finite-float-p value)
       (error 'unsupported-json-value :value value :reason "JSON numbers must be finite"))
     value)
    ((symbolp value)
     (%validate-json-string (%symbol-field-string value)))
    (t (error 'unsupported-json-value :value value
              :reason +unsupported-json-value-reason+))))

(defun %validate-json-record (record)
  (%validate-json-string (%log-record-logger-name record))
  (%validate-json-string (%log-record-message record))
  (dolist (pair (%log-record-fields record) record)
    (%validate-json-string (%json-key-string (car pair)))
    (%validate-json-value (cdr pair))))
