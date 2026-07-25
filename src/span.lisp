;;;; src/span.lisp
;;;
;;; WITH-LOG-SPAN: emit paired :start / :end records around a body, threading a
;;; span id (and parent span id) through *LOG-CONTEXT-FIELDS* so nested spans
;;; form a tree, and classifying the exit as :success, :error, or
;;; :nonlocal-exit.
(in-package #:log-kit)

(defvar *log-span-id* nil)

(defun %monotonic-time ()
  (/ (get-internal-real-time) (float internal-time-units-per-second 1d0)))

;;; Span ids must be unique across every thread in the process: the whole
;;; point of :SPAN-ID (and CAPTURE-LOG-CONTEXT's cross-thread replay) is that
;;; two records carrying the same id belong to the same span. CL:GENSYM does
;;; not provide that — it reads and writes the global *GENSYM-COUNTER*
;;; non-atomically, so concurrent spans hand out duplicate ids (measured: 8
;;; threads x 20,000 spans yielded 39,595 distinct ids out of 160,000). An
;;; ATOMIC-INCF on a dedicated word-typed global is a single lock-xadd, so it
;;; is both correct under concurrency and cheaper than GENSYM's symbol
;;; allocation. Uniqueness is per-process, exactly as it was before; callers
;;; correlating spans across processes should inject their own :ID-SOURCE.
(defstruct (%span-id-counter (:constructor %make-span-id-counter ()))
  ;; SB-EXT:ATOMIC-INCF requires a place it can compile to a bare xadd: a
  ;; DEFSTRUCT slot declared FIXNUM or SB-EXT:WORD is the supported spelling
  ;; (a plain DEFGLOBAL symbol is not).
  (value 0 :type sb-ext:word))

;; DEFINE-LOAD-TIME-GLOBAL, not DEFGLOBAL: DEFGLOBAL also evaluates its value
;; form at compile time, where %MAKE-SPAN-ID-COUNTER — defined just above, in
;; this same file — does not exist yet.
(sb-ext:define-load-time-global **span-id-counter** (%make-span-id-counter))

(defun %next-span-id ()
  ;; ~D, not PRINC: the rendered id must stay decimal regardless of a
  ;; caller-bound *PRINT-BASE*, the same reason %WRITE-INTEGER exists.
  (format nil "SPAN-~D" (sb-ext:atomic-incf (%span-id-counter-value **span-id-counter**))))

(defun %span-fields (span-id parent-span-id event fields &key duration outcome)
  (let ((reserved (append (list :span-id span-id :span-event event)
                          (when parent-span-id (list :parent-span-id parent-span-id))
                          (when duration (list :span-duration duration))
                          (when outcome (list :span-outcome outcome)))))
    (%merge-field-plists reserved
                         (%without-field-keys fields '(:span-id :parent-span-id :span-event
                                                        :span-duration :span-outcome)))))

(defun %call-with-log-span (logger level name fields clock id-source thunk)
  "Run THUNK as the body of a log span: emit a :START record, run THUNK under
a child *LOG-SPAN-ID*/*LOG-CONTEXT-FIELDS*, then always emit a matching :END
record classifying the exit as :SUCCESS, :ERROR, or :NONLOCAL-EXIT. This is
the continuation the WITH-LOG-SPAN macro installs as its body; the macro
itself only decides whether a span is worth starting at all."
  (check-type name string)
  (check-type clock function)
  (check-type id-source function)
  (let* ((span-id (funcall id-source))
         (parent-span-id *log-span-id*)
         (started-at (funcall clock))
         (outcome :nonlocal-exit)
         (primary-condition nil)
         (context-fields (append (list :span-id span-id)
                                 (when parent-span-id (list :parent-span-id parent-span-id)))))
    (check-type span-id string)
    (check-type parent-span-id (or null string))
    (check-type started-at real)
    (%emit-log-unchecked logger level name (%span-fields span-id parent-span-id :start fields))
    (let ((*log-span-id* span-id)
          (*log-context-fields* (%merge-field-alists (plist-to-alist context-fields)
                                                      *log-context-fields*)))
      (unwind-protect
          (handler-bind ((error (lambda (condition)
                                  (setf primary-condition condition
                                        outcome :error))))
            (multiple-value-prog1 (funcall thunk)
              (setf primary-condition nil
                    outcome :success)))
        ;; A failure while emitting the :end record must never mask the
        ;; body's own error; it is only re-signaled when the body succeeded.
        (handler-case
            (let ((finished-at (funcall clock)))
              (check-type finished-at real)
              (%emit-log-unchecked logger level name
                                   (%span-fields span-id parent-span-id :end fields
                                                :duration (- finished-at started-at)
                                                :outcome outcome)))
          (error (cleanup-condition)
            (unless primary-condition
              (error cleanup-condition))))))))

(defmacro with-log-span ((logger name &key (level '+level-info+) fields
                          (clock '#'%monotonic-time) (id-source '#'%next-span-id))
                         &body body)
  "Run BODY as a log span on LOGGER at LEVEL. NAME, FIELDS, CLOCK, and
ID-SOURCE are evaluated only when LEVEL passes LOGGER's filter, so a
filtered span costs nothing beyond the level check."
  (let ((logger-var (gensym "LOGGER"))
        (level-var (gensym "LEVEL")))
    `(let ((,logger-var ,logger)
           (,level-var ,level))
       (if (log-enabled-p ,logger-var ,level-var)
           (%call-with-log-span ,logger-var ,level-var ,name ,fields ,clock ,id-source
                                (lambda () ,@body))
           (progn ,@body)))))
