;;;; src/convenience.lisp

(in-package #:log-kit)

(defun %resolve-logger-message-fields (logger-or-message message-and-fields)
  "LOGGER-OR-MESSAGE is either a LOGGER instance (in which case the first
element of MESSAGE-AND-FIELDS is the message and the rest are the field
plist) or the message itself (in which case *DEFAULT-LOGGER* is used and
all of MESSAGE-AND-FIELDS is the field plist). Returns (values logger
message fields-plist)."
  (if (typep logger-or-message 'logger)
      (values logger-or-message (first message-and-fields) (rest message-and-fields))
      (values *default-logger* logger-or-message message-and-fields)))

(defun %dispatch-log (level logger-or-message message-and-fields)
  "Filter by level and, only if the record would actually be emitted,
build a LOG-RECORD and hand it to the logger's handler exactly once."
  (multiple-value-bind (logger message fields)
      (%resolve-logger-message-fields logger-or-message message-and-fields)
    ;; Levels below the logger's configured level are dropped here, before
    ;; HANDLE-LOG-RECORD is ever called -- no handler work happens for
    ;; filtered-out records.
    (unless (level< level (logger-level logger))
      (let ((record (make-log-record
                     :level level
                     :message message
                     :timestamp (funcall (logger-clock logger))
                     :fields (append (plist-to-alist fields) (logger-fields logger))
                     :logger-name (logger-name logger))))
        (handle-log-record (logger-handler logger) record)))
    (values)))

(defun log-debug (logger-or-message &rest message-and-fields)
  "Log at DEBUG level. See package docstring for the flexible
LOGGER-OR-MESSAGE calling convention."
  (%dispatch-log +level-debug+ logger-or-message message-and-fields))

(defun log-info (logger-or-message &rest message-and-fields)
  "Log at INFO level. See package docstring for the flexible
LOGGER-OR-MESSAGE calling convention."
  (%dispatch-log +level-info+ logger-or-message message-and-fields))

(defun log-warn (logger-or-message &rest message-and-fields)
  "Log at WARN level. See package docstring for the flexible
LOGGER-OR-MESSAGE calling convention."
  (%dispatch-log +level-warn+ logger-or-message message-and-fields))

(defun log-error (logger-or-message &rest message-and-fields)
  "Log at ERROR level. See package docstring for the flexible
LOGGER-OR-MESSAGE calling convention."
  (%dispatch-log +level-error+ logger-or-message message-and-fields))

(defun log-fatal (logger-or-message &rest message-and-fields)
  "Log at FATAL level. See package docstring for the flexible
LOGGER-OR-MESSAGE calling convention."
  (%dispatch-log +level-fatal+ logger-or-message message-and-fields))
