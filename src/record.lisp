;;;; src/record.lisp

(in-package #:log-kit)

(defstruct log-record
  "An immutable snapshot of a single log event, handed to a handler's
HANDLE-LOG-RECORD method exactly once."
  (level +level-info+ :type integer)
  (message "" :type string)
  (timestamp 0)
  (fields nil :type list)
  (logger-name "root" :type string))

(defun plist-to-alist (plist)
  "Convert a plist (:key1 val1 :key2 val2 ...) into an alist
((:key1 . val1) (:key2 . val2) ...)."
  (loop for (key value) on plist by #'cddr
        collect (cons key value)))
