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

(defun %json-key-string (key)
  (etypecase key
    (string key)
    (symbol (string-downcase (symbol-name key)))))

(defun %surrogate-code-point-p (code)
  (<= #xD800 code #xDFFF))

(defun %validate-json-string (value)
  (loop for character across value
        for code = (char-code character)
        when (%surrogate-code-point-p code)
          do (error 'unsupported-json-value :value value
                    :reason "strings must not contain Unicode surrogate code points"))
  value)

(defun %write-json-string (value stream)
  (%validate-json-string value)
  (write-char #\" stream)
  (let ((length (length value))
        (run-start 0))
    (declare (type fixnum length run-start))
    (flet ((flush-run (end)
             (declare (type fixnum end))
             (when (< run-start end)
               (write-string value stream :start run-start :end end))))
      (dotimes (index length)
        (declare (type fixnum index))
        (let* ((character (char value index))
               (code (char-code character))
               (escape (case character
                         (#\" "\\\"")
                         (#\\ "\\\\")
                         (#\Backspace "\\b")
                         (#\Page "\\f")
                         (#\Newline "\\n")
                         (#\Return "\\r")
                         (#\Tab "\\t")
                         (otherwise nil))))
          (cond
            (escape
             (flush-run index)
             (write-string escape stream)
             (setf run-start (1+ index)))
            ((or (< code 32) (= code 127))
             (flush-run index)
             (%write-unicode-escape code stream)
             (setf run-start (1+ index))))))
      (flush-run length)))
  (write-char #\" stream))

(defun %finite-float-p (value)
  (handler-case (let ((difference (- value value)))
                  (and (= value value) (= difference difference)))
    (arithmetic-error () nil)))

(defun %write-json-float (value stream)
  (unless (%finite-float-p value)
    (error 'unsupported-json-value :value value :reason "JSON numbers must be finite"))
  (if (zerop value)
      (write-string (if (minusp (float-sign value)) "-0.0" "0.0") stream)
      (let* ((*print-pretty* nil)
             (*print-readably* t)
             (*print-base* 10)
             (*print-radix* nil)
             (rendered (write-to-string value)))
        ;; SBCL's printer marks single/double/short/long floats with a
        ;; letter exponent (1.5f0, 1.5d0, ...); JSON has no exponent letter
        ;; but 'e', so every implementation-specific marker collapses onto
        ;; the one JSON accepts. Downcasing and normalizing in one pass over
        ;; RENDERED, writing straight to STREAM, avoids the STRING-DOWNCASE
        ;; plus four SUBSTITUTE calls each allocating a full extra copy.
        (loop for character across rendered
              for lower = (char-downcase character)
              do (write-char (case lower ((#\s #\f #\d #\l) #\e) (otherwise lower)) stream)))))

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
    ((integerp value) (format stream "~D" value))
    ((floatp value) (%write-json-float value stream))
    ((symbolp value)
     (%write-json-string (%symbol-field-string value)
                         stream))
    (t (error 'unsupported-json-value :value value
              :reason "supported values are explicit JSON values, strings, integers, finite floats, and symbols"))))

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
              :reason "supported values are explicit JSON values, strings, integers, finite floats, and symbols"))))

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
  (%write-handler-record handler (lambda (stream) (%write-json-record record stream))))
