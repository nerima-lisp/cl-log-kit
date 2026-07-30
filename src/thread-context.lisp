;;;; src/thread-context.lisp
;;;
;;; SB-THREAD:MAKE-THREAD starts a fresh thread with *LOG-CONTEXT-FIELDS* and
;;; *LOG-SPAN-ID* at their global (empty) values — SBCL threads do not
;;; inherit a parent thread's dynamic bindings. CAPTURE-LOG-CONTEXT and
;;; CALL-WITH-CAPTURED-LOG-CONTEXT let a caller snapshot the active
;;; WITH-LOG-CONTEXT fields and WITH-LOG-SPAN span id before spawning a
;;; worker thread, then restore that snapshot inside the worker's body, so
;;; log calls made from the worker still carry the fields and span id the
;;; spawning thread had in scope.
(in-package #:log-kit)

(defstruct (log-context-snapshot (:constructor %make-log-context-snapshot (fields span-id))
                                  (:predicate log-context-snapshot-p)
                                  (:copier nil))
  "An opaque snapshot of one thread's WITH-LOG-CONTEXT fields and
WITH-LOG-SPAN span id, captured by CAPTURE-LOG-CONTEXT for replay in
another thread via WITH-CAPTURED-LOG-CONTEXT."
  (fields nil :read-only t)
  (span-id nil :read-only t))

(document-readers
  (log-context-snapshot-p "True when VALUE is a LOG-CONTEXT-SNAPSHOT created by CAPTURE-LOG-CONTEXT."))

(defun capture-log-context ()
  "Snapshot the calling thread's active WITH-LOG-CONTEXT fields and
WITH-LOG-SPAN span id, for later replay in another thread via
CALL-WITH-CAPTURED-LOG-CONTEXT or WITH-CAPTURED-LOG-CONTEXT."
  (%make-log-context-snapshot *log-context-fields* *log-span-id*))

(defun call-with-captured-log-context (snapshot thunk)
  "Call THUNK with *LOG-CONTEXT-FIELDS* and *LOG-SPAN-ID* rebound to
SNAPSHOT's values, so log calls inside THUNK behave as if made from the
thread that captured SNAPSHOT via CAPTURE-LOG-CONTEXT."
  (check-type snapshot log-context-snapshot)
  (let ((*log-context-fields* (log-context-snapshot-fields snapshot))
        (*log-span-id* (log-context-snapshot-span-id snapshot)))
    (funcall thunk)))

(defmacro with-captured-log-context ((snapshot) &body body)
  "Run BODY with the logging context and span id captured in SNAPSHOT (see
CAPTURE-LOG-CONTEXT) rebound as the active state, typically from inside a
new thread's body."
  `(call-with-captured-log-context ,snapshot (lambda () ,@body)))
