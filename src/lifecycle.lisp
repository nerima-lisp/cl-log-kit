;;;; src/lifecycle.lisp
;;;
;;; CLOSE-MANAGED-HANDLER: the reusable, thread-safe close/operation lifecycle
;;; shared by every composite handler. %CALL-WITH-OPEN-HANDLER-OPERATION and
;;; %CALL-CLOSE-ONCE are CPS entry points that admit an operation only while
;;; the handler is open and guarantee a single close even under concurrent
;;; and re-entrant callers. handlers.lisp builds the concrete handlers on top.
(in-package #:log-kit)

(defun %validate-error-policy (policy callback)
  (unless (member policy '(:signal :continue :callback) :test #'eq)
    (error 'type-error :datum policy :expected-type '(member :signal :continue :callback)))
  (when (and (eq policy :callback) (not (functionp callback)))
    (error 'type-error :datum callback :expected-type 'function)))

(defun %handle-operation-error (policy callback operation target condition)
  (ecase policy
    (:signal (error condition))
    (:continue nil)
    (:callback (funcall callback operation target condition) nil)))

(define-condition handler-lifecycle-error (log-kit-error)
  ((handler :initarg :handler :reader handler-lifecycle-error-handler
            :documentation "The handler the disallowed operation was attempted on.")
   (operation :initarg :operation :reader handler-lifecycle-error-operation
              :documentation "A keyword naming the attempted operation, e.g. :HANDLE,
:FLUSH, or :CLOSE.")
   (state :initarg :state :reader handler-lifecycle-error-state
          :documentation "The handler's lifecycle state that made OPERATION invalid,
e.g. :ACTIVE-OPERATION when a handler tries to close itself from within its
own HANDLE-LOG-RECORD/FLUSH-HANDLER method."))
  (:report (lambda (condition stream)
             (format stream "Cannot perform ~S on a handler in lifecycle state ~S."
                     (handler-lifecycle-error-operation condition)
                     (handler-lifecycle-error-state condition))))
  (:documentation "Signaled when an operation is attempted on a
CLOSE-MANAGED-HANDLER outside the lifecycle state that allows it — most
commonly a handler trying to close itself from inside its own
HANDLE-LOG-RECORD or FLUSH-HANDLER method, which would deadlock."))

;;; DEFINE-CONDITION's per-slot :DOCUMENTATION only reaches MOP slot
;;; introspection, not (DOCUMENTATION #'READER 'FUNCTION); set the latter
;;; explicitly so the reader generic functions answer DOCUMENTATION too.
(setf (documentation 'handler-lifecycle-error-handler 'function)
      "The handler the disallowed operation was attempted on.")
(setf (documentation 'handler-lifecycle-error-operation 'function)
      "A keyword naming the attempted operation, e.g. :HANDLE, :FLUSH, or :CLOSE.")
(setf (documentation 'handler-lifecycle-error-state 'function)
      "The handler's lifecycle state that made OPERATION invalid.")

;;; Handlers currently running an admitted operation on the calling thread,
;;; so %CALL-CLOSE-ONCE can refuse a handler trying to close itself from
;;; inside its own HANDLE-LOG-RECORD/FLUSH-HANDLER method.
(defvar *active-close-managed-handlers* nil)

(defclass close-managed-handler (handler)
  ((close-lock :initform (sb-thread:make-mutex :name "cl-log-kit handler close")
              :reader %close-managed-lock)
   (close-waitqueue :initform (sb-thread:make-waitqueue :name "cl-log-kit handler close")
                    :reader %close-managed-waitqueue)
   (close-state :initform :open :accessor %close-managed-state)
   (close-owner :initform nil :accessor %close-managed-owner)
   (active-operations :initform 0 :accessor %close-managed-active-operations)))

(defun %lifecycle-error (handler operation state)
  (error 'handler-lifecycle-error :handler handler :operation operation :state state))

(defun %call-with-open-handler-operation (handler operation function)
  "Call FUNCTION as OPERATION on HANDLER, admitted only while HANDLER is
open. Marks HANDLER active for the duration so a nested close attempt from
within FUNCTION is refused instead of deadlocking against itself."
  (let ((entered-p nil))
    (unwind-protect
        (progn
          (sb-thread:with-mutex ((%close-managed-lock handler))
            (let ((state (%close-managed-state handler)))
              (unless (eq state :open)
                (%lifecycle-error handler operation state))
              (incf (%close-managed-active-operations handler))
              (setf entered-p t)))
          (let ((*active-close-managed-handlers* (cons handler *active-close-managed-handlers*)))
            (funcall function)))
      (when entered-p
        (sb-thread:with-mutex ((%close-managed-lock handler))
          (decf (%close-managed-active-operations handler))
          (sb-thread:condition-broadcast (%close-managed-waitqueue handler)))))
    handler))

(defun %call-close-once (handler function)
  "Call FUNCTION to close HANDLER at most once, no matter how many threads
call CLOSE-HANDLER concurrently: the first caller runs FUNCTION while later
callers wait for it to finish, and a caller already inside an admitted
operation on HANDLER is refused outright."
  (when (member handler *active-close-managed-handlers* :test #'eq)
    (%lifecycle-error handler :close :active-operation))
  (let ((run-close-p nil)
        (thread sb-thread:*current-thread*))
    (sb-thread:with-mutex ((%close-managed-lock handler))
      (loop
        (case (%close-managed-state handler)
          (:open
           (setf (%close-managed-state handler) :closing
                 (%close-managed-owner handler) thread
                 run-close-p t)
           (loop while (plusp (%close-managed-active-operations handler))
                 do (sb-thread:condition-wait (%close-managed-waitqueue handler)
                                              (%close-managed-lock handler)))
           (return))
          (:closed (return))
          (:closing
           (if (eq (%close-managed-owner handler) thread)
               (return)
               (sb-thread:condition-wait (%close-managed-waitqueue handler)
                                         (%close-managed-lock handler)))))))
    (when run-close-p
      (let ((completed-p nil))
        (unwind-protect
            (progn
              (funcall function)
              (setf completed-p t))
          (sb-thread:with-mutex ((%close-managed-lock handler))
            (setf (%close-managed-state handler) (if completed-p :closed :open)
                  (%close-managed-owner handler) nil)
            (sb-thread:condition-broadcast (%close-managed-waitqueue handler))))))
    handler))

;;; The three macros below are the managed-handler method DSL: they turn a
;;; method body into the continuation passed to %CALL-WITH-OPEN-HANDLER-OPERATION
;;; (handle/flush, admitted only while open) or %CALL-CLOSE-ONCE (close, run at
;;; most once). Every composite handler defines its methods through them, so the
;;; lifecycle-guard boilerplate lives here exactly once.

(defmacro defhandle (class (handler record) &body body)
  "Define a HANDLE-LOG-RECORD method for CLASS whose BODY runs only while the
handler is open."
  `(defmethod handle-log-record ((,handler ,class) ,record)
     (%call-with-open-handler-operation ,handler :handle (lambda () ,@body))))

(defmacro defflush (class (handler) &body body)
  "Define a FLUSH-HANDLER method for CLASS whose BODY runs only while the
handler is open."
  `(defmethod flush-handler ((,handler ,class))
     (%call-with-open-handler-operation ,handler :flush (lambda () ,@body))))

(defmacro defclose (class (handler) &body body)
  "Define a CLOSE-HANDLER method for CLASS whose BODY runs at most once."
  `(defmethod close-handler ((,handler ,class))
     (%call-close-once ,handler (lambda () ,@body))))
