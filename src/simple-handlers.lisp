;;;; src/simple-handlers.lisp
;;;
;;; The single-child/no-child handlers built on the lifecycle.lisp backbone:
;;; FILTER-HANDLER (predicate gate), FUNCTION-HANDLER (adapt a closure), and
;;; NULL-HANDLER. Also the stream-handler constructor table
;;; (DEFINE-STREAM-HANDLER-CONSTRUCTORS), HANDLER-OPEN-P introspection, and
;;; WITH-HANDLER. MULTI-HANDLER, the fan-out composite, lives in
;;; handlers.lisp alongside FLUSH-LOGGER.
(in-package #:log-kit)

(defclass filter-handler (close-managed-handler)
  ((target :initarg :target :reader %filter-handler-target)
   (predicate :initarg :predicate :reader %filter-handler-predicate))
  (:documentation "Forwards a record to TARGET only when PREDICATE returns
true of it. See MAKE-FILTER-HANDLER."))

(defmethod initialize-instance :after ((instance filter-handler) &key target predicate)
  (declare (ignore instance))
  (check-type target handler)
  (check-type predicate function))

(defun make-filter-handler (target predicate)
  "Build a handler that forwards a record to TARGET only when (FUNCALL
PREDICATE RECORD) is true."
  (make-instance 'filter-handler :target target :predicate predicate))

(defhandle filter-handler (handler record)
  (when (funcall (%filter-handler-predicate handler) record)
    (handle-log-record (%filter-handler-target handler) record)))

(defflush filter-handler (handler)
  (flush-handler (%filter-handler-target handler)))

(defclose filter-handler (handler)
  (close-handler (%filter-handler-target handler)))

(defclass function-handler (close-managed-handler)
  ((handle-function :initarg :handle-function :reader %function-handler-handle)
   (flush-function :initarg :flush-function :initform nil :reader %function-handler-flush)
   (close-function :initarg :close-function :initform nil :reader %function-handler-close))
  (:documentation "Adapts a plain closure to the handler protocol: each
record is handed to HANDLE-FUNCTION. See MAKE-FUNCTION-HANDLER."))

(defmethod initialize-instance :after ((instance function-handler) &key handle-function
                                       flush-function close-function)
  (declare (ignore instance))
  (check-type handle-function function)
  (when flush-function (check-type flush-function function))
  (when close-function (check-type close-function function)))

(defun make-function-handler (handle-function &key flush-function close-function)
  "Build a handler that calls (FUNCALL HANDLE-FUNCTION RECORD) for every
record. FLUSH-FUNCTION and CLOSE-FUNCTION, if supplied, are called with no
arguments by FLUSH-HANDLER and CLOSE-HANDLER respectively; omitted, those
operations are no-ops."
  (make-instance 'function-handler :handle-function handle-function :flush-function flush-function
                                   :close-function close-function))

(defhandle function-handler (handler record)
  (funcall (%function-handler-handle handler) record))

(defflush function-handler (handler)
  (when (%function-handler-flush handler)
    (funcall (%function-handler-flush handler))))

(defclose function-handler (handler)
  (when (%function-handler-close handler)
    (funcall (%function-handler-close handler))))

(defclass null-handler (handler)
  ()
  (:documentation "Discards every record. See MAKE-NULL-HANDLER."))

(defun make-null-handler ()
  "Build a handler that discards every record it receives."
  (make-instance 'null-handler))

(defmethod handle-log-record ((handler null-handler) record)
  (declare (ignore record))
  handler)

(defmacro define-stream-handler-constructors (&body specs)
  "Generate one MAKE-<NAME>-HANDLER constructor per (constructor class) pair in
SPECS, matching the data-table style DEFINE-LOG-LEVEL-MACROS already uses for
the LOG-<LEVEL> family: the shared :stream/:auto-flush/:owns-stream surface is
written once, and each generated function is a plain, directly testable defun."
  `(progn
     ,@(loop for (constructor class) in specs
             collect `(defun-defaulted ,constructor (&key (stream *standard-output*)
                                                           (auto-flush t)
                                                           (owns-stream nil))
                        ,(format nil "Build a ~(~A~) writing to STREAM (default *STANDARD-OUTPUT*).
When AUTO-FLUSH is true (the default), STREAM is flushed after every write.
When OWNS-STREAM is true, CLOSE-HANDLER also closes STREAM." class)
                        (make-instance (quote ,class) :stream stream :auto-flush auto-flush
                                       :owns-stream owns-stream)))))

(define-stream-handler-constructors
  (make-text-handler text-handler)
  (make-json-handler json-handler))

(defgeneric handler-open-p (handler)
  (:documentation "Return true when HANDLER currently accepts handle and flush operations."))

(defmethod handler-open-p ((handler handler)) t)

(defmethod handler-open-p ((handler %stream-handler))
  (let ((state (%handler-stream-state handler)))
    (cl-concurrent-kit:with-lock-held ((%stream-state-lock state))
      (not (or (%handler-closed-p handler)
               (%stream-state-closing-p state)
               (%stream-state-closed-p state))))))

(defmethod handler-open-p ((handler close-managed-handler))
  (cl-concurrent-kit:with-lock-held ((%close-managed-lock handler))
    (eq (%close-managed-state handler) :open)))

(defmacro with-handler ((variable form) &body body)
  "Bind VARIABLE to FORM and run BODY, closing VARIABLE's handler on exit
whether BODY returns normally or unwinds."
  `(let ((,variable ,form))
     (check-type ,variable handler)
     (unwind-protect (progn ,@body)
       (close-handler ,variable))))
