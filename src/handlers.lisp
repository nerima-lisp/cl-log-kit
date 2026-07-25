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
   (error-callback :initarg :error-callback :initform nil :reader %composition-error-callback)))

(defmethod initialize-instance :after ((instance multi-handler) &key (handlers (%constant-default nil))
                                       (error-policy (%constant-default :signal)) error-callback)
  (unless (%proper-list-p handlers)
    (%invalid-fields handlers "handler collection must be a finite proper list"))
  (dolist (target handlers)
    (check-type target handler))
  (unless (= (length handlers) (length (remove-duplicates handlers :test #'eq)))
    (error 'program-error))
  (%validate-error-policy error-policy error-callback)
  (setf (slot-value instance 'handlers) (copy-list handlers)))

(defun make-multi-handler (handlers &key (error-policy (%constant-default :signal)) error-callback)
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
   (predicate :initarg :predicate :reader %filter-handler-predicate)))

(defmethod initialize-instance :after ((instance filter-handler) &key target predicate)
  (declare (ignore instance))
  (check-type target handler)
  (check-type predicate function))

(defun make-filter-handler (target predicate)
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
   (close-function :initarg :close-function :initform nil :reader %function-handler-close)))

(defmethod initialize-instance :after ((instance function-handler) &key handle-function
                                       flush-function close-function)
  (declare (ignore instance))
  (check-type handle-function function)
  (when flush-function (check-type flush-function function))
  (when close-function (check-type close-function function)))

(defun make-function-handler (handle-function &key flush-function close-function)
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

(defclass null-handler (handler) ())

(defun make-null-handler ()
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
  (check-type logger logger)
  (flush-handler (logger-handler logger))
  logger)
