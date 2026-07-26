;;;; src/handler-json.lisp
;;;
;;; json-handler wire format: one strict RFC 8259 JSON object per line. The
;;; record is validated up front (finite numbers, no surrogate code points)
;;; so a partially written object can never reach the stream.
(in-package #:log-kit)

;;; This file's hot path runs on every enabled log call. SAFETY 1 (not 0)
;;; keeps ordinary type checking — including the resource-limit guards
;;; elsewhere in the library that depend on catchable type/range errors —
;;; while SPEED 3 lets SBCL apply the same optimizations a caller would get
;;; from per-function (OPTIMIZE ...) declarations, without repeating them
;;; on every DEFUN in the file.
(declaim (optimize (speed 3) (safety 1) (compilation-speed 0)))

;;; Named once so the writer and the validator report the same reason: the two
;;; walk the same type dispatch, and a reader who hits one message must be able
;;; to trust it describes the other path too.
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
  ;; A BASE-STRING holds only base-chars (code < 128 on SBCL), so it can never
  ;; contain a Unicode surrogate (#xD800..#xDFFF): the whole scan is provably
  ;; unnecessary and collapses to a single widetag test. ASCII log text — the
  ;; overwhelming common case — takes exactly this exit.
  (unless (typep value 'base-string)
    ;; Otherwise dispatch once on simple-ness and index with SCHAR, avoiding
    ;; the generic hairy-array element reader; a non-simple string (rare) is
    ;; coerced once up front.
    (let ((string (if (simple-string-p value) value (coerce value 'simple-string))))
      (declare (type simple-string string))
      (dotimes (index (length string))
        (declare (type fixnum index))
        (when (%surrogate-code-point-p (char-code (schar string index)))
          (error 'unsupported-json-value :value value
                 :reason "strings must not contain Unicode surrogate code points")))))
  value)

(defun %write-json-string (value stream)
  ;; No surrogate re-validation here: every write path reaches this function
  ;; only after HANDLE-LOG-RECORD has run %VALIDATE-JSON-RECORD over the whole
  ;; record (and the fixed structural keys it also emits are ASCII literals),
  ;; so the string is already known surrogate-free. Re-scanning it here just
  ;; to re-derive that fact was a third full pass over every field string.
  (write-char #\" stream)
  ;; Bind STRING to a guaranteed-simple copy of VALUE (a no-op for the common
  ;; already-simple string) so both the per-character SCHAR below and the
  ;; run-flushing WRITE-STRING take the fast simple-array path.
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
          ;; Fast path (see the matching note in handler-text's
          ;; %WRITE-TEXT-VALUE): a printable ASCII character escapes only if it
          ;; is a quote or backslash, so ordinary text stays in the current
          ;; run with one range test and two comparisons and never computes
          ;; CHAR-CODE. The seven C0 escapes and the generic control escape
          ;; live on the rare non-printable branch.
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
      ;; Binding *READ-DEFAULT-FLOAT-FORMAT* to VALUE's own type makes SBCL's
      ;; printer emit the exponent marker as a bare 'e' (or omit it) instead
      ;; of the type-specific letter (1.5d0, 1.5f0, ...) — so the printed form
      ;; is already strict RFC 8259, needing neither an intermediate string
      ;; nor a normalizing pass. PRIN1 straight to STREAM then conses nothing
      ;; per call (WRITE-TO-STRING allocated a full fresh string every time).
      ;; SBCL aliases SHORT-FLOAT to SINGLE-FLOAT and LONG-FLOAT to
      ;; DOUBLE-FLOAT, so these two branches cover all four float types.
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

(defun %write-json-field (key value first-p stream)
  (unless first-p (write-char #\, stream))
  (%write-json-string (%json-key-string key) stream)
  (write-char #\: stream)
  (%write-json-value value stream))

(defun %write-json-members (members stream)
  "Write MEMBERS, an alist of (key . value) pairs, as one brace-delimited JSON
object. Shared by %WRITE-JSON-OBJECT (explicit nested objects) and the record
`fields` object, so both render members through exactly one loop."
  (write-char #\{ stream)
  (loop for pair in members
        for first = t then nil
        do (unless first (write-char #\, stream))
           (%write-json-string (%json-key-string (car pair)) stream)
           (write-char #\: stream)
           (%write-json-value (cdr pair) stream))
  (write-char #\} stream))

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

(defun %write-json-record (record output)
  (write-char #\{ output)
  (%write-json-field "time" (log-record-timestamp record) t output)
  (%write-json-field "level" (level-name (log-record-level record)) nil output)
  (%write-json-field "logger" (%log-record-logger-name record) nil output)
  (%write-json-field "message" (%log-record-message record) nil output)
  (write-string ",\"fields\":" output)
  (%write-json-members (%log-record-fields record) output)
  (write-char #\} output)
  (write-char #\Newline output))

(defmethod handle-log-record ((handler json-handler) record)
  (check-type record log-record)
  (%validate-json-record record)
  ;; Stack-allocate the writer closure: %WRITE-HANDLER-RECORD invokes it
  ;; synchronously under the stream lock and never stores it, so its extent is
  ;; dynamic and the capture of RECORD need not touch the heap.
  (flet ((writer (stream) (%write-json-record record stream)))
    (declare (dynamic-extent #'writer))
    (%write-handler-record handler #'writer)))
