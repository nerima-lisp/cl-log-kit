;;;; src/convenience.lisp
;;;
;;; The core logging surface: the level check, the single emit path
;;; (%EMIT-LOG-UNCHECKED), and the LOG / LOG-DEFAULT / LOG-<LEVEL> macro
;;; families generated from one data table by DEFINE-LOG-LEVEL-MACROS. The
;;; field-plist helpers at the bottom are shared by condition-logging.lisp
;;; and span.lisp.
(in-package #:log-kit)

;;; %EMIT-LOG-UNCHECKED is the single path every enabled log call reaches.
;;; SAFETY 1 (not 0) keeps ordinary type checking; SPEED 3 optimizes the
;;; level check and field-merge machinery it drives.
(declaim (optimize (speed 3) (safety 1) (compilation-speed 0)))

(defun log-enabled-p (logger level)
  (check-type logger logger)
  (check-type level integer)
  (>= level (logger-level logger)))

(defun %emit-log-unchecked (logger level message fields-plist)
  "Build and hand a LOG-RECORD to LOGGER's handler without checking
LOG-ENABLED-P first. Every LOG-* macro already checks the level before
reaching here, so this is the one place a record is actually constructed
and emitted."
  (check-type message string)
  (let* ((event-fields (plist-to-alist fields-plist))
         (context-fields (if *log-context-fields*
                             (%merge-field-alists *log-context-fields* (%logger-fields logger))
                             (%logger-fields logger)))
         (fields (%merge-field-alists event-fields context-fields))
         (record (%build-log-record level message (funcall (logger-clock logger)) fields
                                    (%logger-name logger))))
    (handle-log-record (logger-handler logger) record)
    record))

(defun emit-log (logger level message &optional (fields-plist (%constant-default nil)))
  (check-type logger logger)
  (check-type level integer)
  (when (log-enabled-p logger level)
    (%emit-log-unchecked logger level message fields-plist)))

(defmacro with-default-logger ((logger) &body body)
  `(let ((*default-logger* ,logger))
     (check-type *default-logger* logger)
     ,@body))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %expand-log-form (logger level message fields)
    "Expand to code that checks LOG-ENABLED-P once, evaluating LOGGER and
LEVEL exactly once and MESSAGE/FIELDS not at all when the event is
filtered."
    (let ((logger-var (gensym "LOGGER"))
          (level-var (gensym "LEVEL")))
      `(let ((,logger-var ,logger)
             (,level-var ,level))
         (when (log-enabled-p ,logger-var ,level-var)
           (%emit-log-unchecked ,logger-var ,level-var ,message (list ,@fields))))))

  (defun %expand-log-level-form (logger-or-message arguments level)
    ;; Default calls have 2N trailing fields; explicit calls have a message plus 2N.
    (if (evenp (length arguments))
        (%expand-log-form '*default-logger* level logger-or-message arguments)
        (%expand-log-form logger-or-message level (first arguments) (rest arguments)))))

(defmacro log (logger level message &rest fields)
  (%expand-log-form logger level message fields))

(defmacro log-default (level message &rest fields)
  (%expand-log-form '*default-logger* level message fields))

(defmacro define-log-level-macros (&body specs)
  "Generate dual-convention LOG-<LEVEL> and explicit LOG-DEFAULT-<LEVEL> macros."
  `(progn
     ,@(loop for (explicit default level) in specs
             collect `(defmacro ,explicit (logger-or-message &rest arguments)
                        (%expand-log-level-form logger-or-message arguments ',level))
             collect `(defmacro ,default (message &rest fields)
                        (%expand-log-form '*default-logger* ',level message fields)))))

(define-log-level-macros
  (log-debug log-default-debug +level-debug+)
  (log-info  log-default-info  +level-info+)
  (log-warn  log-default-warn  +level-warn+)
  (log-error log-default-error +level-error+)
  (log-fatal log-default-fatal +level-fatal+))

(defun %field-alist-to-plist (fields)
  (loop for (key . value) in fields append (list key value)))

(defun %merge-field-plists (preferred fallback)
  (%field-alist-to-plist (%merge-field-alists (plist-to-alist preferred) (plist-to-alist fallback))))

(defun %without-field-keys (fields keys)
  (%field-alist-to-plist
   (remove-if (lambda (field) (member (car field) keys :test #'eq)) (plist-to-alist fields))))
