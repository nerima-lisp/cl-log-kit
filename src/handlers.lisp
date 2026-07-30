;;;; src/handlers.lisp
;;;
;;; MULTI-HANDLER: the fan-out composite built on the lifecycle.lisp
;;; backbone, applying an error policy (:SIGNAL, :CONTINUE, or :CALLBACK)
;;; across its children. Also FLUSH-LOGGER. The single/no-child handlers
;;; (FILTER-HANDLER, FUNCTION-HANDLER, NULL-HANDLER) live in
;;; simple-handlers.lisp.
(in-package #:log-kit)

(defclass multi-handler (close-managed-handler)
  ((handlers :initarg :handlers :reader %multi-handler-handlers)
   (error-policy :initarg :error-policy :initform :signal :reader %composition-error-policy)
   (error-callback :initarg :error-callback :initform nil :reader %composition-error-callback))
  (:documentation "Fans a record out to every child handler in HANDLERS,
applying ERROR-POLICY (:SIGNAL, :CONTINUE, or :CALLBACK) when a child
signals. See MAKE-MULTI-HANDLER."))

(defmethod-defaulted initialize-instance :after ((instance multi-handler)
                                                  &key (handlers nil)
                                                  (error-policy :signal)
                                                  error-callback)
  (unless (%proper-list-p handlers)
    (%invalid-fields handlers "handler collection must be a finite proper list"))
  (dolist (target handlers)
    (check-type target handler))
  (unless (= (length handlers) (length (remove-duplicates handlers :test #'eq)))
    (error 'program-error))
  (%validate-error-policy error-policy error-callback)
  (setf (slot-value instance 'handlers) (copy-list handlers)))

(defun-defaulted make-multi-handler (handlers &key (error-policy :signal) error-callback)
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

(defun flush-logger (logger)
  "Flush LOGGER's handler and return LOGGER."
  (check-type logger logger)
  (flush-handler (logger-handler logger))
  logger)
