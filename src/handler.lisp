;;;; src/handler.lisp
;;;
;;; Handler protocol and the stream backbone shared by every stream-backed
;;; handler. The concrete wire formats live in their own files:
;;; handler-text.lisp (key=value text) and handler-json.lisp (one JSON object
;;; per line).
;;;
;;; The Handler protocol is the structural fix for the "log line printed
;;; twice" bug that was found in cl-cc's ad-hoc logger (where a text-mode
;;; branch printed a message with %LOG-EMIT-TEXT and a second, unrelated
;;; code path printed the very same message again). HANDLE-LOG-RECORD is
;;; the *only* place a handler is allowed to write output, and every
;;; built-in handler method performs exactly one write call to its stream.
;;; There is no second code path that could duplicate output.
(in-package #:log-kit)

(defclass handler () ())

(defgeneric handle-log-record (handler record)
  (:documentation "Emit RECORD exactly once through HANDLER."))

(defgeneric flush-handler (handler)
  (:documentation "Flush buffered output for HANDLER."))

(defgeneric close-handler (handler)
  (:documentation "Close HANDLER and its stream when the handler owns it."))

(defmethod flush-handler ((handler handler)) handler)
(defmethod close-handler ((handler handler)) handler)

;;; Every physical output stream shared by one or more handlers gets exactly
;;; one %STREAM-STATE, keyed weakly on the stream itself, so handlers that
;;; wrap the *same* stream (e.g. two JSON handlers around one socket) agree
;;; on a single write lock and a single close.
(defstruct (%stream-state (:constructor %make-stream-state (lock waitqueue)))
  lock
  waitqueue
  (active-operations 0 :type fixnum)
  operation-owner
  (operation-depth 0 :type fixnum)
  finalizing-owner
  (close-pending-p nil :type boolean)
  (closing-p nil :type boolean)
  (closed-p nil :type boolean)
  (waiters 0 :type fixnum))

(defvar *stream-state-registry-lock* (sb-thread:make-mutex :name "cl-log-kit stream registry"))
(defvar *stream-state-registry* (make-hash-table :test #'eq :weakness :key))

(defun %stream-state-for (stream)
  (sb-thread:with-mutex (*stream-state-registry-lock*)
    (or (gethash stream *stream-state-registry*)
        (setf (gethash stream *stream-state-registry*)
              (%make-stream-state (sb-thread:make-mutex :name "cl-log-kit stream output")
                                  (sb-thread:make-waitqueue :name "cl-log-kit stream lifecycle"))))))

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

(defclass text-handler (%stream-handler) ())
(defclass json-handler (%stream-handler) ())

(defun %ensure-open-handler (handler state)
  (when (or (%handler-closed-p handler)
            (%stream-state-closing-p state)
            (%stream-state-closed-p state))
    (error 'stream-error :stream (%handler-stream handler))))

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
    (sb-thread:condition-broadcast (%stream-state-waitqueue state))))

(defun %finalize-stream-close (state stream)
  (sb-thread:with-mutex ((%stream-state-lock state))
    (setf (%stream-state-finalizing-owner state) sb-thread:*current-thread*))
  (unwind-protect
      (unwind-protect (finish-output stream)
        (close stream))
    (sb-thread:with-mutex ((%stream-state-lock state))
      (setf (%stream-state-finalizing-owner state) nil
            (%stream-state-closing-p state) nil
            (%stream-state-closed-p state) t)
      (%notify-stream-waiters state))))

(defun %begin-stream-operation (handler)
  "Admit the calling thread as an owner of HANDLER's stream write lock,
waiting out any other owner first. Re-entrant: a thread that already owns
the lock (e.g. a nested write from a FINISH-OUTPUT callback) is admitted
immediately instead of deadlocking on itself."
  (let ((state (%handler-stream-state handler))
        (thread sb-thread:*current-thread*))
    (sb-thread:with-mutex ((%stream-state-lock state))
      (%ensure-open-handler handler state)
      (let ((waited-p nil))
        (unwind-protect
            (loop while (and (%stream-state-operation-owner state)
                             (not (eq (%stream-state-operation-owner state) thread)))
                  do (unless waited-p
                       (incf (%stream-state-waiters state))
                       (setf waited-p t))
                     (sb-thread:condition-wait (%stream-state-waitqueue state) (%stream-state-lock state))
                     (%ensure-open-handler handler state))
          (when waited-p (decf (%stream-state-waiters state)))))
      (setf (%stream-state-operation-owner state) thread)
      (incf (%stream-state-operation-depth state))
      (incf (%stream-state-active-operations state)))
    state))

(defun %end-stream-operation (state stream)
  (let ((close-stream-p nil))
    (sb-thread:with-mutex ((%stream-state-lock state))
      (decf (%stream-state-active-operations state))
      (decf (%stream-state-operation-depth state))
      (when (zerop (%stream-state-operation-depth state))
        (setf (%stream-state-operation-owner state) nil)
        (%notify-stream-waiters state))
      (when (and (%stream-state-close-pending-p state) (zerop (%stream-state-active-operations state)))
        (setf (%stream-state-close-pending-p state) nil
              close-stream-p t))
      (when (zerop (%stream-state-active-operations state))
        (%notify-stream-waiters state)))
    (when close-stream-p
      (%finalize-stream-close state stream))))

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
  (labels ((%wait-until-stream-closed (state)
             (incf (%stream-state-waiters state))
             (unwind-protect
                 (loop until (%stream-state-closed-p state)
                       do (sb-thread:condition-wait (%stream-state-waitqueue state) (%stream-state-lock state)))
               (decf (%stream-state-waiters state))))
           (%wait-until-no-active-operations (state)
             (incf (%stream-state-waiters state))
             (unwind-protect
                 (loop until (zerop (%stream-state-active-operations state))
                       do (sb-thread:condition-wait (%stream-state-waitqueue state) (%stream-state-lock state)))
               (decf (%stream-state-waiters state))))
           (%thread-owns-stream-operation-p (state)
             (or (eq (%stream-state-operation-owner state) sb-thread:*current-thread*)
                 (eq (%stream-state-finalizing-owner state) sb-thread:*current-thread*)))
           (%begin-owned-close (state)
             "Called once, with the write lock held, the first time this
handler closes an owned stream. Negotiates closing ownership with any other
owner, returning true only when this call must perform the physical close."
             (cond
               ((%stream-state-closing-p state)
                (unless (%thread-owns-stream-operation-p state)
                  (%wait-until-stream-closed state))
                nil)
               ((eq (%stream-state-operation-owner state) sb-thread:*current-thread*)
                ;; This thread already holds the write lock (e.g. closing
                ;; from inside a FINISH-OUTPUT callback): defer the physical
                ;; close until that operation unwinds instead of closing
                ;; under it.
                (setf (%stream-state-closing-p state) t
                      (%stream-state-close-pending-p state) t)
                (%notify-stream-waiters state)
                nil)
               (t
                (setf (%stream-state-closing-p state) t)
                (%notify-stream-waiters state)
                (%wait-until-no-active-operations state)
                t))))
    (let ((stream (%handler-stream handler))
          (state (%handler-stream-state handler))
          (close-stream-p nil))
      (sb-thread:with-mutex ((%stream-state-lock state))
        (cond
          ((not (%handler-owns-stream-p handler)) (setf (%handler-closed-p handler) t))
          ((%stream-state-closed-p state) (setf (%handler-closed-p handler) t))
          ((%handler-closed-p handler)
           ;; Already closed by this handler; if another owner is still
           ;; physically closing the stream, wait for that to finish so a
           ;; caller never observes CLOSE-HANDLER return before the stream
           ;; itself is closed.
           (when (and (%stream-state-closing-p state) (not (%thread-owns-stream-operation-p state)))
             (%wait-until-stream-closed state)))
          (t
           (setf (%handler-closed-p handler) t)
           (setf close-stream-p (%begin-owned-close state)))))
      (when close-stream-p
        (%finalize-stream-close state stream))
      handler)))

;;; Shared low-level escape used by both the text and JSON encoders: render a
;;; code point as a \uXXXX escape. It lives in the backbone so neither
;;; concrete encoder file has to depend on the other.
(defun %write-unicode-escape (code stream)
  (format stream "\\u~4,'0X" code))

;;; Shared fast integer writer. PRINC / WRITE route a plain integer through
;;; OUTPUT-OBJECT and the pretty-print dispatch table before ever emitting a
;;; digit — pure overhead on a hot log field. Emitting the base-10 digits
;;; directly is both faster and allocation-free, and — because it derives each
;;; digit from (REM n 10) — it is always decimal regardless of a caller-bound
;;; *PRINT-BASE*, which the JSON encoder needs for RFC 8259 conformance.
;;; The (OPTIMIZE ...) declarations below are per-function, not a file-level
;;; DECLAIM, so the SPEED 3 policy cannot leak into later-loaded source files.
(defun %write-nonneg-fixnum-digits (n stream)
  (declare (type (and fixnum unsigned-byte) n)
           (optimize (speed 3) (safety 1)))
  (when (>= n 10)
    (%write-nonneg-fixnum-digits (truncate n 10) stream))
  (write-char (code-char (+ 48 (rem n 10))) stream))

(defun %write-neg-fixnum-digits (n stream)
  ;; N <= 0 throughout: the magnitude's digits are derived in negative space
  ;; ((- 48 (rem n 10))) so MOST-NEGATIVE-FIXNUM, whose (- n) is not a fixnum,
  ;; still prints without overflow.
  (declare (type (and fixnum (integer * 0)) n)
           (optimize (speed 3) (safety 1)))
  (when (<= n -10)
    (%write-neg-fixnum-digits (truncate n 10) stream))
  (write-char (code-char (- 48 (rem n 10))) stream))

(defun %write-integer (n stream)
  "Write N to STREAM as base-10 digits, allocation-free for the fixnum case."
  (declare (type integer n) (optimize (speed 3) (safety 1)))
  (cond ((not (typep n 'fixnum)) (princ n stream)) ; bignum: rare, defer to the printer
        ((minusp n) (write-char #\- stream) (%write-neg-fixnum-digits n stream))
        (t (%write-nonneg-fixnum-digits n stream))))

;;; Downcased-keyword-name cache. Rendering a keyword field key or value means
;;; STRING-DOWNCASE'ing its symbol name, which allocates a fresh string on
;;; every log call — and real workloads reuse the same small set of keys
;;; (:method, :path, :status, ...) across millions of records. Interning each
;;; keyword's downcased name once removes that per-call allocation entirely.
;;;
;;; Concurrency: the published table is immutable. A cache miss builds a NEW
;;; table (old entries + the one new keyword) under a lock and atomically
;;; swaps the global pointer, so a reader is always traversing a table no
;;; thread will ever mutate — the lock-free hit path is a single plain
;;; GETHASH with no data race against a concurrent grow/rehash. Misses are
;;; rare (one per distinct keyword, for the process lifetime), so the O(n)
;;; copy-on-write cost is paid a handful of times, never on the steady state.
(sb-ext:defglobal **keyword-name-cache** (make-hash-table :test #'eq))
(defvar *keyword-name-cache-lock*
  (sb-thread:make-mutex :name "cl-log-kit keyword name cache"))

(defun %cached-keyword-name (keyword)
  "Return KEYWORD's downcased symbol name, interning it on first use so later
calls reuse the same string instead of reallocating it."
  (or (gethash keyword **keyword-name-cache**)
      (sb-thread:with-mutex (*keyword-name-cache-lock*)
        (or (gethash keyword **keyword-name-cache**)
            (let* ((rendered (string-downcase (symbol-name keyword)))
                   (old **keyword-name-cache**)
                   (new (make-hash-table :test #'eq :size (1+ (hash-table-count old)))))
              (maphash (lambda (k v) (setf (gethash k new) v)) old)
              (setf (gethash keyword new) rendered)
              ;; Publish the fully built replacement in one atomic store; every
              ;; reader either sees the old table or the new one, never a
              ;; half-populated one.
              (setf **keyword-name-cache** new)
              rendered)))))

;;; Shared symbol-to-field-string rule used by both encoders: a keyword's
;;; name is downcased (so :active reads as "active"), any other symbol's
;;; name is left in its native case.
(defun %symbol-field-string (value)
  (if (keywordp value) (%cached-keyword-name value) (symbol-name value)))
