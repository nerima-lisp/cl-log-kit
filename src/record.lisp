;;;; src/record.lisp
;;;
;;; LOG-RECORD: the immutable value that flows from a logger to a handler.
;;; Construction snapshots the message, logger name, and fields (via
;;; snapshot.lisp) so a record can never observe a later mutation.
(in-package #:log-kit)

(defstruct (log-record
            (:constructor %make-log-record-from-snapshot
                          (&key level message timestamp fields logger-name))
            (:conc-name %log-record-))
  "An immutable snapshot of a single log event."
  (level +level-info+ :type integer :read-only t)
  (message "" :type string :read-only t)
  (timestamp 0 :type integer :read-only t)
  (fields nil :type list :read-only t)
  (logger-name "root" :type string :read-only t))

(defun %build-log-record (level message timestamp fields logger-name)
  (check-types (level integer) (message string) (timestamp integer) (logger-name string))
  (%check-field-string-length message)
  (%check-field-string-length logger-name)
  (%make-log-record-from-snapshot :level level
                                  :message (copy-seq message)
                                  :timestamp timestamp
                                  :fields fields
                                  :logger-name (copy-seq logger-name)))

(defun make-log-record (&key (level (%constant-default +level-info+)) (message (%constant-default ""))
                        (timestamp (%constant-default 0)) (fields (%constant-default nil))
                        (logger-name (%constant-default "root")))
  (%build-log-record level message timestamp (plist-to-alist fields) logger-name))

(defun log-record-level (record)
  (%log-record-level record))

(defun log-record-message (record)
  (copy-seq (%log-record-message record)))

(defun log-record-timestamp (record)
  (%log-record-timestamp record))

(defun log-record-fields (record)
  (%copy-field-alist (%log-record-fields record)))

(defun log-record-logger-name (record)
  (copy-seq (%log-record-logger-name record)))
