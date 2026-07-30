;;;; src/log-context.lisp
;;;
;;; WITH-LOG-CONTEXT: dynamically scoped field merging, independent of any
;;; particular logger instance. Loads before logger.lisp so LOGGER-WITH/
;;; LOGGER-CHILD there can reuse %MERGE-FIELD-ALISTS.
(in-package #:log-kit)

(defvar *log-context-fields* nil
  "Dynamically scoped field snapshot used by WITH-LOG-CONTEXT.")

(defun %merge-field-alists (overrides base)
  "Merge two field alists, keeping the first entry seen for each canonical
key: every pair in OVERRIDES, then every pair in BASE whose key OVERRIDES
did not already claim."
  (let ((seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (pair overrides)
      (setf (gethash (%canonical-field-name (car pair)) seen) t)
      (push (cons (car pair) (cdr pair)) result))
    (dolist (pair base)
      (unless (gethash (%canonical-field-name (car pair)) seen)
        (push (cons (car pair) (cdr pair)) result)))
    (nreverse result)))

(defmacro with-log-context ((&rest fields) &body body)
  "Run BODY with FIELDS merged onto the dynamically scoped log context, so
every log call made anywhere in BODY (not just calls with LOGGER directly in
scope) picks them up until BODY returns."
  `(let ((*log-context-fields* (%merge-field-alists (plist-to-alist (list ,@fields))
                                                     *log-context-fields*)))
     ,@body))
