(in-package #:log-kit)

;;; Shared streams use one weakly keyed state, lock, and close lifecycle.
(defstruct (%stream-state (:constructor %make-stream-state (lock waitqueue)))
  lock
  waitqueue
  (active-operations 0 :type fixnum)
  operation-owner
  (operation-depth 0 :type fixnum)
  finalizing-owner
  (close-state :open :type (member :open :close-pending :closing :closed))
  (waiters 0 :type fixnum))

(defun %stream-state-close-pending-p (state)
  (eq (%stream-state-close-state state) :close-pending))

(defun %stream-state-closing-p (state)
  "True while STATE is anywhere between a close being requested and the
physical stream close finishing: :CLOSE-PENDING or :CLOSING."
  (case (%stream-state-close-state state)
    ((:close-pending :closing) t)
    (t nil)))

(defun %stream-state-closed-p (state)
  (eq (%stream-state-close-state state) :closed))

(defvar *stream-state-registry-lock* (cl-concurrent-kit:make-lock :name "cl-log-kit stream registry"))

(defvar *stream-state-registry* (make-hash-table :test #'eq :weakness :key))

(defun %stream-state-for (stream)
  (cl-concurrent-kit:with-lock-held (*stream-state-registry-lock*)
    (or (gethash stream *stream-state-registry*)
        (setf (gethash stream *stream-state-registry*)
              (%make-stream-state
               (cl-concurrent-kit:make-lock :name "cl-log-kit stream output")
               (cl-concurrent-kit:make-condition-variable :name "cl-log-kit stream lifecycle"))))))

(defun %notify-stream-waiters (state)
  "Broadcast STATE's waitqueue only when a thread is actually blocked on it.
CONDITION-BROADCAST makes a real kernel wake-all call even with zero
waiters (profiling showed this dominating over 95% of per-call time on the
unconditional-broadcast version), so skipping it on the overwhelmingly
common uncontended path removes the single largest cost of every log call.
Safe to skip: a thread only increments WAITERS immediately before calling
CONDITION-WAIT, and both that increment and this check happen only while
holding STATE's lock, so no notification sent while a thread is genuinely
blocked can ever be skipped — see %BEGIN-STREAM-OPERATION and
%WAIT-UNTIL-STREAM-CLOSED, the only two places WAITERS changes."
  (when (plusp (%stream-state-waiters state))
    (cl-concurrent-kit:condition-broadcast (%stream-state-waitqueue state))))

(defun %finalize-stream-close (state stream)
  (cl-concurrent-kit:with-lock-held ((%stream-state-lock state))
    (setf (%stream-state-finalizing-owner state) sb-thread:*current-thread*))
  (unwind-protect
      (unwind-protect (finish-output stream)
        (close stream))
    (cl-concurrent-kit:with-lock-held ((%stream-state-lock state))
      (setf (%stream-state-finalizing-owner state) nil
            (%stream-state-close-state state) :closed)
      (%notify-stream-waiters state))))

(defun %end-stream-operation (state stream)
  (let ((close-stream-p nil))
    (cl-concurrent-kit:with-lock-held ((%stream-state-lock state))
      (decf (%stream-state-active-operations state))
      (decf (%stream-state-operation-depth state))
      (when (zerop (%stream-state-operation-depth state))
        (setf (%stream-state-operation-owner state) nil)
        (%notify-stream-waiters state))
      (when (and (%stream-state-close-pending-p state)
                 (zerop (%stream-state-active-operations state)))
        (setf (%stream-state-close-state state) :closing
              close-stream-p t))
      (when (zerop (%stream-state-active-operations state))
        (%notify-stream-waiters state)))
    (when close-stream-p
      (%finalize-stream-close state stream))))

(defun %wait-on-stream-condition (state predicate)
  "Block the calling thread on STATE's waitqueue until (FUNCALL PREDICATE
STATE) is true, tracking STATE's waiter count around the wait so
%NOTIFY-STREAM-WAITERS knows whether a broadcast is needed. Must be called
with STATE's lock held; CONDITION-WAIT releases and reacquires it."
  (incf (%stream-state-waiters state))
  (unwind-protect
      (loop until (funcall predicate state)
            do (cl-concurrent-kit:condition-wait (%stream-state-waitqueue state)
                                                 (%stream-state-lock state)))
    (decf (%stream-state-waiters state))))

(defun %thread-owns-stream-operation-p (state)
  (or (eq (%stream-state-operation-owner state) sb-thread:*current-thread*)
      (eq (%stream-state-finalizing-owner state) sb-thread:*current-thread*)))

(defun %begin-owned-close (state)
  "Called once, with the write lock held, the first time this handler
closes an owned stream. Negotiates closing ownership with any other owner,
returning true only when this call must perform the physical close."
  (cond
    ((%stream-state-closing-p state)
     (unless (%thread-owns-stream-operation-p state)
       (%wait-on-stream-condition state #'%stream-state-closed-p))
     nil)
    ((eq (%stream-state-operation-owner state) sb-thread:*current-thread*)
     ;; This thread already holds the write lock (e.g. closing from inside
     ;; a FINISH-OUTPUT callback): defer the physical close until that
     ;; operation unwinds instead of closing under it.
     (setf (%stream-state-close-state state) :close-pending)
     (%notify-stream-waiters state)
     nil)
    (t
     (setf (%stream-state-close-state state) :closing)
     (%notify-stream-waiters state)
     (%wait-on-stream-condition state (lambda (s) (zerop (%stream-state-active-operations s))))
     t)))
