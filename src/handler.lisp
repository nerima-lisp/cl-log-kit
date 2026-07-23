;;;; src/handler.lisp
;;;
;;; The Handler protocol is the structural fix for the "log line printed
;;; twice" bug that was found in cl-cc's ad-hoc logger (where a text-mode
;;; branch printed a message with %LOG-EMIT-TEXT and a second, unrelated
;;; code path printed the very same message again). HANDLE-LOG-RECORD is
;;; the *only* place a handler is allowed to write output, and every
;;; built-in handler method below performs exactly one write call to its
;;; stream. There is no second code path that could duplicate output.

(in-package #:log-kit)

(defclass handler ()
  ()
  (:documentation "Base class for all log handlers. Subclasses implement
HANDLE-LOG-RECORD to consume a LOG-RECORD exactly once."))

(defgeneric handle-log-record (handler record)
  (:documentation "Emit RECORD via HANDLER. Implementations must perform
exactly one output operation per call -- never call another emission
function from within this method, and never let a caller invoke it more
than once for the same record."))

;;; ---------------------------------------------------------------------
;;; text-handler: "[LEVEL] message key=value key=value" on one line.
;;; ---------------------------------------------------------------------

(defclass text-handler (handler)
  ((stream :initarg :stream :accessor text-handler-stream
           :initform *standard-output*))
  (:documentation "Writes one human-readable line per log record."))

(defun %field-key-name (key)
  "Render a field alist KEY (typically a keyword) as a lower-case string,
e.g. :PORT -> \"port\"."
  (if (symbolp key)
      (string-downcase (symbol-name key))
      (princ-to-string key)))

(defun %format-text-fields (fields)
  "Render FIELDS (an alist) as \" key=value key=value\", or the empty
string when FIELDS is empty."
  (with-output-to-string (out)
    (dolist (pair fields)
      (format out " ~A=~A" (%field-key-name (car pair)) (cdr pair)))))

(defmethod handle-log-record ((handler text-handler) (record log-record))
  ;; Single, sole write to the stream -- this is the entire body of the
  ;; method. Do not add a second output form here.
  (format (text-handler-stream handler)
          "[~A] ~A~A~%"
          (level-name (log-record-level record))
          (log-record-message record)
          (%format-text-fields (log-record-fields record))))

;;; ---------------------------------------------------------------------
;;; json-handler: one JSON object per line.
;;; ---------------------------------------------------------------------

(defclass json-handler (handler)
  ((stream :initarg :stream :accessor json-handler-stream
           :initform *standard-output*))
  (:documentation "Writes one JSON object per log record, one per line."))

(defun json-escape-string (string)
  "Escape STRING for embedding inside a JSON string literal: quotes,
backslashes, newlines, tabs, and other control characters."
  (with-output-to-string (out)
    (loop for char across string do
      (case char
        (#\" (write-string "\\\"" out))
        (#\\ (write-string "\\\\" out))
        (#\Newline (write-string "\\n" out))
        (#\Tab (write-string "\\t" out))
        (#\Return (write-string "\\r" out))
        (t (if (< (char-code char) #x20)
               (format out "\\u~4,'0X" (char-code char))
               (write-char char out)))))))

(defun json-encode-value (value)
  "Return VALUE encoded as a JSON literal (a string)."
  (cond
    ((null value) "null")
    ((eq value t) "true")
    ((stringp value) (format nil "\"~A\"" (json-escape-string value)))
    ((numberp value) (princ-to-string value))
    ((keywordp value) (format nil "\"~A\"" (json-escape-string (string-downcase (symbol-name value)))))
    ((symbolp value) (format nil "\"~A\"" (json-escape-string (string value))))
    (t (format nil "\"~A\"" (json-escape-string (princ-to-string value))))))

(defun %json-fields (fields)
  "Render FIELDS (an alist) as \"key\":value,\"key\":value pairs (no
leading/trailing comma), or the empty string when FIELDS is empty."
  (with-output-to-string (out)
    (dolist (pair fields)
      (format out ",\"~A\":~A"
              (json-escape-string (%field-key-name (car pair)))
              (json-encode-value (cdr pair))))))

(defmethod handle-log-record ((handler json-handler) (record log-record))
  ;; Single, sole write to the stream -- the whole JSON object is built as
  ;; one string and written with one call.
  (format (json-handler-stream handler)
          "{\"timestamp\":~A,\"level\":\"~A\",\"message\":\"~A\",\"logger\":\"~A\"~A}~%"
          (json-encode-value (log-record-timestamp record))
          (json-escape-string (level-name (log-record-level record)))
          (json-escape-string (log-record-message record))
          (json-escape-string (log-record-logger-name record))
          (%json-fields (log-record-fields record))))
