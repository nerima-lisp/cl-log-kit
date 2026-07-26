;;;; src/handlers.lisp
;;;
;;; The composite and terminal handlers built on the lifecycle.lisp backbone:
;;; MULTI-HANDLER (fan-out with an error policy), FILTER-HANDLER (predicate
;;; gate), FUNCTION-HANDLER (adapt a closure), and NULL-HANDLER. Also the
;;; public constructors (MAKE-*-HANDLER), HANDLER-OPEN-P introspection,
;;; WITH-HANDLER, and FLUSH-LOGGER.
(in-package #:log-kit)

(defclass multi-handler (close-managed-handler)
  ((handlers :initarg :handlers :reader %multi-handler-handlers)
   (error-policy :initarg :error-policy :initform :signal :reader %composition-error-policy)
   (error-callback :initarg :error-callback :initform nil :reader %composition-error-callback))
  (:documentation "Fans a record out to every child handler in HANDLERS,
applying ERROR-POLICY (:SIGNAL, :CONTINUE, or :CALLBACK) when a child
signals. See MAKE-MULTI-HANDLER."))

(defmethod initialize-instance :after ((instance multi-handler)
                                       &key (handlers (%constant-default nil))
                                       (error-policy (%constant-default :signal))
                                       error-callback)
  (unless (%proper-list-p handlers)
    (%invalid-fields handlers "handler collection must be a finite proper list"))
  (dolist (target handlers)
    (check-type target handler))
  (unless (= (length handlers) (length (remove-duplicates handlers :test #'eq)))
    (error 'program-error))
  (%validate-error-policy error-policy error-callback)
  (setf (slot-value instance 'handlers) (copy-list handlers)))

(defun make-multi-handler (handlers &key (error-policy (%constant-default :signal)) error-callback)
  "Build a handler that forwards every record to each handler in HANDLERS (a
proper list with no duplicates). ERROR-POLICY governs what happens when a
child signals: :SIGNAL (the default) stops the pass and re-signals;
:CONTINUE swallows the error and proceeds to the remaining children;
:CALLBACK calls ERROR-CALLBACK with (OPERATION TARGET CONDITION) and then
proceeds. CLOSE-HANDLER is the exception to :SIGNAL's stop-at-the-first-error
rule: every child is given a chance to close, and only then is the first
error re-signaled, so one child's failure cannot leak the rest."
  (make-instance 'multi-handler :handlers handlers :error-policy error-policy
                                :error-callback error-callback))

(defun %map-multi-handler (handler operation function &key complete-before-signaling)
  "Call FUNCTION with each of HANDLER's child handlers. Every child is tried
even after one fails: when COMPLETE-BEFORE-SIGNALING is true (used by
DEFCLOSE), the first error is remembered and re-signaled only after every
child has had a chance to close, instead of a mid-list failure aborting
close for the rest."
  (let ((first-error nil))
    (labels ((remember-error (condition)
               (unless first-error
                 (setf first-error condition)))
             (apply-error-policy (target condition)
               (%handle-operation-error (%composition-error-policy handler)
                                        (%composition-error-callback handler)
                                        operation target condition))
             (handle-immediate-failure (target condition)
               ;; Handle/flush: run the policy now, so :signal aborts the pass.
               (apply-error-policy target condition))
             (handle-deferred-failure (target condition)
               ;; Close: keep going. Remember the first error, then run the
               ;; policy callback for its side effects (never :signal, which
               ;; would abort the close pass), capturing a callback that itself
               ;; fails as the error to re-signal.
               (remember-error condition)
               (unless (eq (%composition-error-policy handler) :signal)
                 (handler-case (apply-error-policy target condition)
                   (error (callback-error) (remember-error callback-error))))))
      (dolist (target (%multi-handler-handlers handler))
        (handler-case (funcall function target)
          (error (condition)
            (if complete-before-signaling
                (handle-deferred-failure target condition)
                (handle-immediate-failure target condition)))))
      (when first-error
        (error first-error))
      handler)))

(defhandle multi-handler (handler record)
  (%map-multi-handler handler :handle (lambda (target) (handle-log-record target record))))

(defflush multi-handler (handler)
  (%map-multi-handler handler :flush #'flush-handler))

(defclose multi-handler (handler)
  (%map-multi-handler handler :close #'close-handler :complete-before-signaling t))

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
             collect `(defun ,constructor (&key (stream (%constant-default *standard-output*))
                                                 (auto-flush (%constant-default t))
                                                 (owns-stream (%constant-default nil)))
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
    (sb-thread:with-mutex ((%stream-state-lock state))
      (not (or (%handler-closed-p handler)
               (%stream-state-closing-p state)
               (%stream-state-closed-p state))))))

(defmethod handler-open-p ((handler close-managed-handler))
  (sb-thread:with-mutex ((%close-managed-lock handler))
    (eq (%close-managed-state handler) :open)))

(defmacro with-handler ((variable form) &body body)
  "Bind VARIABLE to FORM and run BODY, closing VARIABLE's handler on exit
whether BODY returns normally or unwinds."
  `(let ((,variable ,form))
     (check-type ,variable handler)
     (unwind-protect (progn ,@body)
       (close-handler ,variable))))

(defun flush-logger (logger)
  "Flush LOGGER's handler and return LOGGER."
  (check-type logger logger)
  (flush-handler (logger-handler logger))
  logger)
