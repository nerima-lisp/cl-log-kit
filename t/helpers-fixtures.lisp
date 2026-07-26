;;;; t/helpers-fixtures.lisp
;;;
;;; Shared test toolkit: the fixtures and helpers every spec file builds on.
;;; Keeping them here (loaded first) means no spec file has to reach into
;;; another for a handler class or a signalling helper.
(in-package #:cl-log-kit/test)

;;; A handler that records every record it receives, newest first. RECORDS
;;; returns them in emission order so assertions read chronologically.
(defclass counting-handler (handler)
  ((records :initform nil :accessor counting-handler-records)))

(defmethod handle-log-record ((handler counting-handler) record)
  (push record (counting-handler-records handler))
  handler)

(defun counting-handler-in-order (handler)
  "The records HANDLER captured, oldest first."
  (reverse (counting-handler-records handler)))

(defun latest-record (handler)
  "The most recent record HANDLER captured."
  (first (counting-handler-records handler)))

(defun latest-fields (handler)
  "The fields of the most recent record HANDLER captured."
  (log-record-fields (latest-record handler)))

;;; Build a log record with sensible, overridable defaults.
(defun make-test-record (&key (level +level-info+) (message "hello")
                              (timestamp 42) (fields nil) (logger-name "root"))
  (make-log-record :level level :message message :timestamp timestamp
                   :fields fields :logger-name logger-name))

;;; Render RECORD through a fresh stream handler of CLASS and return the text.
(defun render-through (class record)
  (with-output-to-string (stream)
    (handle-log-record (make-instance class :stream stream) record)))

;;; Render VALUE as a single JSON field. Callers pair this with CL-WEAVE:SIGNALS
;;; to assert it raises UNSUPPORTED-JSON-VALUE.
(defun render-json-value (value)
  (render-through 'json-handler (make-test-record :fields (list :value value))))

;;; A logger writing text to a private string stream, plus a thunk that
;;; drains that stream. Returns (values logger drain).
(defun capturing-logger (&key (level +level-info+) fields (clock #'get-universal-time))
  (let* ((stream (make-string-output-stream))
         (logger (make-logger :handler (make-instance 'text-handler :stream stream)
                              :level level :fields fields :clock clock)))
    (values logger (lambda () (get-output-stream-string stream)))))

;;; True when two structural copies share no mutable substructure: no EQ cons
;;; cell and no EQ non-empty string. This is the identity half of the snapshot
;;; guarantee — that later mutation of one value can never reach the other.
(defun shares-no-structure-p (a b)
  (cond
    ((and (consp a) (consp b))
     (and (not (eq a b))
          (shares-no-structure-p (car a) (car b))
          (shares-no-structure-p (cdr a) (cdr b))))
    ((and (stringp a) (stringp b))
     (or (zerop (length a)) (not (eq a b))))
    (t t)))

;;; A logger backed by a counting-handler. Returns (values logger handler).
(defun counting-logger (&rest logger-args)
  (let ((handler (make-instance 'counting-handler)))
    (values (apply #'make-logger :handler handler logger-args) handler)))
