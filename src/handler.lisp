;;;; src/handler.lisp
;;;
;;; Handler protocol and the stream backbone shared by every stream-backed
;;; handler. The concrete wire formats live in their own files:
;;; handler-text.lisp (key=value text) and handler-json.lisp (one JSON object
;;; per line), and the low-level encoding primitives both of them share live
;;; in encoding.lisp.
;;;
;;; The Handler protocol is the structural fix for the "log line printed
;;; twice" bug that was found in cl-cc's ad-hoc logger (where a text-mode
;;; branch printed a message with %LOG-EMIT-TEXT and a second, unrelated
;;; code path printed the very same message again). HANDLE-LOG-RECORD is
;;; the *only* place a handler is allowed to write output, and every
;;; built-in handler method performs exactly one write call to its stream.
;;; There is no second code path that could duplicate output.
(in-package #:log-kit)

(defclass handler ()
  ()
  (:documentation "Base class of the handler protocol. Every concrete handler
implements HANDLE-LOG-RECORD, and may specialize FLUSH-HANDLER and
CLOSE-HANDLER, to emit a LOG-RECORD exactly once."))

(defgeneric handle-log-record (handler record)
  (:documentation "Emit RECORD exactly once through HANDLER."))

(defgeneric flush-handler (handler)
  (:documentation "Flush buffered output for HANDLER."))

(defgeneric close-handler (handler)
  (:documentation "Close HANDLER and its stream when the handler owns it."))

(defmethod flush-handler ((handler handler)) handler)
(defmethod close-handler ((handler handler)) handler)

(defclass %stream-handler (handler)
  ((stream :initarg :stream :initform *standard-output* :reader %handler-stream)
   (stream-state :reader %handler-stream-state)
   (auto-flush :initarg :auto-flush :initform t :reader %handler-auto-flush-p)
   (owns-stream :initarg :owns-stream :initform nil :reader %handler-owns-stream-p)
   (closed-p :initform nil :accessor %handler-closed-p)))

(defun %check-boolean-initarg (value)
  (unless (typep value 'boolean)
    (error 'type-error :datum value :expected-type 'boolean)))

(defmethod initialize-instance :after ((handler %stream-handler) &key)
  (let ((stream (%handler-stream handler)))
    (unless (and (streamp stream) (output-stream-p stream))
      (error 'type-error :datum stream :expected-type '(and stream (satisfies output-stream-p))))
    (%check-boolean-initarg (%handler-auto-flush-p handler))
    (%check-boolean-initarg (%handler-owns-stream-p handler))
    (setf (slot-value handler 'stream-state) (%stream-state-for stream))))

(defclass text-handler (%stream-handler)
  ()
  (:documentation "Writes one escaped `ts=... level=... logger=... msg=...
field.\"k\"=\"v\"` line per record. See MAKE-TEXT-HANDLER."))

(defclass json-handler (%stream-handler)
  ()
  (:documentation "Writes one strict RFC 8259 JSON object per line. See
MAKE-JSON-HANDLER."))

(defun %ensure-open-handler (handler state)
  (when (or (%handler-closed-p handler)
            (%stream-state-closing-p state)
            (%stream-state-closed-p state))
    (error 'stream-error :stream (%handler-stream handler))))

(defun %begin-stream-operation (handler)
  "Admit the calling thread as an owner of HANDLER's stream write lock,
waiting out any other owner first. Re-entrant: a thread that already owns
the lock (e.g. a nested write from a FINISH-OUTPUT callback) is admitted
immediately instead of deadlocking on itself."
  (let ((state (%handler-stream-state handler))
        (thread sb-thread:*current-thread*))
    (cl-concurrent-kit:with-lock-held ((%stream-state-lock state))
      (%ensure-open-handler handler state)
      (let ((waited-p nil))
        (unwind-protect
            (loop while (and (%stream-state-operation-owner state)
                             (not (eq (%stream-state-operation-owner state) thread)))
                  do (unless waited-p
                       (incf (%stream-state-waiters state))
                       (setf waited-p t))
                     (cl-concurrent-kit:condition-wait (%stream-state-waitqueue state)
                                                       (%stream-state-lock state))
                     (%ensure-open-handler handler state))
          (when waited-p (decf (%stream-state-waiters state)))))
      (setf (%stream-state-operation-owner state) thread)
      (incf (%stream-state-operation-depth state))
      (incf (%stream-state-active-operations state)))
    state))

(defun %write-handler-record (handler writer)
  "Call WRITER with HANDLER's stream under the write lock, then flush if
HANDLER auto-flushes. The lock/unlock pair around WRITER is the only place a
handler is allowed to touch its stream, which is what keeps concurrent
writers from interleaving a partial record."
  (let ((state (%begin-stream-operation handler))
        (stream (%handler-stream handler)))
    (unwind-protect
        (progn
          (funcall writer stream)
          (when (%handler-auto-flush-p handler)
            (finish-output stream)))
      (%end-stream-operation state stream)))
  handler)

(defmethod flush-handler ((handler %stream-handler))
  (let ((state (%begin-stream-operation handler))
        (stream (%handler-stream handler)))
    (unwind-protect (finish-output stream)
      (%end-stream-operation state stream)))
  handler)

(defmethod close-handler ((handler %stream-handler))
  (let ((stream (%handler-stream handler))
        (state (%handler-stream-state handler))
        (close-stream-p nil))
    (cl-concurrent-kit:with-lock-held ((%stream-state-lock state))
      (cond
        ((not (%handler-owns-stream-p handler)) (setf (%handler-closed-p handler) t))
        ((%stream-state-closed-p state) (setf (%handler-closed-p handler) t))
        ((%handler-closed-p handler)
         ;; Already closed by this handler; if another owner is still
         ;; physically closing the stream, wait for that to finish so a
         ;; caller never observes CLOSE-HANDLER return before the stream
         ;; itself is closed.
         (when (and (%stream-state-closing-p state) (not (%thread-owns-stream-operation-p state)))
           (%wait-on-stream-condition state #'%stream-state-closed-p)))
        (t
         (setf (%handler-closed-p handler) t)
         (setf close-stream-p (%begin-owned-close state)))))
    (when close-stream-p
      (%finalize-stream-close state stream))
    handler))
