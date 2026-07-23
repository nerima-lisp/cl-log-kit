;;;; src/logger.lisp

(in-package #:log-kit)

(defclass logger ()
  ((name :initarg :name :reader logger-name :initform "root")
   (handler :initarg :handler :reader logger-handler)
   (level :initarg :level :reader logger-level :initform +level-info+)
   (fields :initarg :fields :reader logger-fields :initform nil)
   (clock :initarg :clock :reader logger-clock :initform #'get-universal-time))
  (:documentation "Binds a name, a handler, a minimum level, contextual
fields, and a clock (timestamp source, overridable for deterministic
tests)."))

(defun make-logger (&key (name "root")
                       (handler (make-instance 'text-handler))
                       (level +level-info+)
                       fields
                       (clock #'get-universal-time))
  "Create a new LOGGER. FIELDS is a plist (:key1 val1 :key2 val2 ...) of
context that will be attached to every record this logger emits."
  (make-instance 'logger
                  :name name
                  :handler handler
                  :level level
                  :fields (plist-to-alist fields)
                  :clock clock))

(defun logger-with (logger &rest fields)
  "Return a *new* logger that shares LOGGER's name, handler, level, and
clock, but whose fields are LOGGER's fields merged with FIELDS (a plist).
LOGGER itself is never mutated, so previously created loggers (including
LOGGER) keep seeing their own, unaffected field set."
  (make-instance 'logger
                  :name (logger-name logger)
                  :handler (logger-handler logger)
                  :level (logger-level logger)
                  :fields (append (plist-to-alist fields) (logger-fields logger))
                  :clock (logger-clock logger)))

(defvar *default-logger* (make-logger)
  "The logger used by LOG-DEBUG/LOG-INFO/LOG-WARN/LOG-ERROR/LOG-FATAL when
no explicit logger is passed as their first argument.")

(defun set-default-logger (logger)
  "Replace *DEFAULT-LOGGER* with LOGGER."
  (check-type logger logger)
  (setf *default-logger* logger))
