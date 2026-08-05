;;;; src/handler-json.lisp
;;;
;;; json-handler wire format: one strict RFC 8259 JSON object per line,
;;; built on json-encoding.lisp's value writers/validators.
(in-package #:log-kit)

;;; This file's hot path runs on every enabled log call. SAFETY 1 (not 0)
;;; keeps ordinary type checking — including the resource-limit guards
;;; elsewhere in the library that depend on catchable type/range errors —
;;; while SPEED 3 lets SBCL apply the same optimizations a caller would get
;;; from per-function (OPTIMIZE ...) declarations, without repeating them
;;; on every DEFUN in the file.
(declaim (optimize (speed 3) (safety 1) (compilation-speed 0)))

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

(defstream-handle json-handler (handler record) #'%write-json-record :validator #'%validate-json-record)
