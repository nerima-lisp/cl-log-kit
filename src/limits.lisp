;;;; src/limits.lisp
;;;
;;; The resource-bound constants and the guards that signal
;;; LOG-RESOURCE-LIMIT-EXCEEDED (conditions.lisp) when a field value's depth,
;;; node count, string length, or collection size exceeds them, so a hostile
;;; or accidentally huge value can never exhaust memory or loop unboundedly.
(in-package #:log-kit)

(defconstant +max-log-field-depth+ 64)

(defconstant +max-log-field-nodes+ 65536)

(defconstant +max-log-field-string-length+ 1048576)

(defconstant +max-log-field-array-elements+ 16384)

(defun %resource-limit-exceeded (resource limit actual)
  (error 'log-resource-limit-exceeded :resource resource :limit limit :actual actual))

(defun %check-snapshot-size (resource actual limit)
  (when (> actual limit)
    (%resource-limit-exceeded resource limit actual)))

(defun %check-field-string-length (string)
  "Signal LOG-RESOURCE-LIMIT-EXCEEDED when STRING exceeds the field
string-length bound. The single place that bound is applied, so record,
logger, and snapshot code state the intent instead of repeating the resource
keyword and constant."
  (%check-snapshot-size :string-length (length string) +max-log-field-string-length+))

(defun %bounded-proper-list-length (value limit resource reason)
  "The length of VALUE, bounded by LIMIT and cycle-checked in one pass, so a
caller never has to fully traverse a hostile or circular list to reject it."
  (loop with tail = value
        with slow = value
        with fast = value
        for count from 0
        do (cond
             ((null tail) (return count))
             ((atom tail) (%invalid-fields value reason)))
           (when (= count limit)
             (%resource-limit-exceeded resource limit (1+ limit)))
           (setf tail (cdr tail))
           (if (and (consp fast) (consp (cdr fast)))
               (progn
                 (setf slow (cdr slow)
                       fast (cddr fast))
                 (when (eq slow fast)
                   (%invalid-fields value reason)))
               (setf fast nil))))
