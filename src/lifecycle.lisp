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

;;; Handlers currently running an admitted operation on the calling thread,
;;; so %CALL-CLOSE-ONCE can refuse a handler trying to close itself from
;;; inside its own HANDLE-LOG-RECORD/FLUSH-HANDLER method.
(defvar *active-close-managed-handlers* nil)

(defclass close-managed-handler (handler)
  ((close-lock :initform (cl-concurrent-kit:make-lock :name "cl-log-kit handler close")
              :reader %close-managed-lock)
   (close-waitqueue :initform (cl-concurrent-kit:make-condition-variable :name "cl-log-kit handler close")
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
          (cl-concurrent-kit:with-lock-held ((%close-managed-lock handler))
            (let ((state (%close-managed-state handler)))
              (unless (eq state :open)
                (%lifecycle-error handler operation state))
              (incf (%close-managed-active-operations handler))
              (setf entered-p t)))
          (let ((*active-close-managed-handlers* (cons handler *active-close-managed-handlers*)))
            (funcall function)))
      (when entered-p
        (cl-concurrent-kit:with-lock-held ((%close-managed-lock handler))
          (decf (%close-managed-active-operations handler))
          (cl-concurrent-kit:condition-broadcast (%close-managed-waitqueue handler)))))
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
    (cl-concurrent-kit:with-lock-held ((%close-managed-lock handler))
      (loop
        (case (%close-managed-state handler)
          (:open
           (setf (%close-managed-state handler) :closing
                 (%close-managed-owner handler) thread
                 run-close-p t)
           (loop while (plusp (%close-managed-active-operations handler))
                 do (cl-concurrent-kit:condition-wait (%close-managed-waitqueue handler)
                                                      (%close-managed-lock handler)))
           (return))
          (:closed (return))
          (:closing
           (if (eq (%close-managed-owner handler) thread)
               (return)
               (cl-concurrent-kit:condition-wait (%close-managed-waitqueue handler)
                                                 (%close-managed-lock handler)))))))
    (when run-close-p
      (let ((completed-p nil))
        (unwind-protect
            (progn
              (funcall function)
              (setf completed-p t))
          (cl-concurrent-kit:with-lock-held ((%close-managed-lock handler))
            (setf (%close-managed-state handler) (if completed-p :closed :open)
                  (%close-managed-owner handler) nil)
            (cl-concurrent-kit:condition-broadcast (%close-managed-waitqueue handler))))))
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
