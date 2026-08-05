;;;; src/snapshot.lisp
;;;
;;; The deep, bounded, cycle-checked snapshot that copies every field value
;;; before it enters an immutable log record. This is what makes a record a
;;; true point-in-time snapshot the caller can no longer mutate. The explicit
;;; JSON value model (null/false sentinels, object/array wrappers) this
;;; snapshot walks lives in json-values.lisp.
(in-package #:log-kit)

;;; This file's recursive snapshot walk runs on every field of every enabled
;;; log call. SAFETY 1 (not 0) keeps the type/range checks the resource
;;; limits below depend on; SPEED 3 optimizes the traversal itself.
(declaim (optimize (speed 3) (safety 1) (compilation-speed 0)))

(defun %canonical-field-name (key)
  (let ((name (etypecase key
                (symbol (symbol-name key))
                (string key))))
    (%check-field-string-length name)
    (string-downcase name)))

(defun %copy-field-key (key)
  (if (stringp key)
      (progn
        (%check-field-string-length key)
        (copy-seq key))
      key))

(defun %copy-field-pair (pair)
  "Copy one (KEY . VALUE) field pair the way every public field reader does:
a defensively copied key and a fresh snapshot of the value."
  (cons (%copy-field-key (car pair)) (%snapshot-field-value (cdr pair))))

(defun %check-duplicate-canonical-key (canonical seen fields reason)
  (when (gethash canonical seen)
    (%invalid-fields fields reason))
  (setf (gethash canonical seen) t))

(defun %validate-field-key (key fields)
  (unless (or (symbolp key) (stringp key))
    (%invalid-fields fields "field keys must be symbols or strings")))

(defstruct (%snapshot-context (:constructor %make-snapshot-context ()))
  (nodes 0 :type fixnum)
  active)

(defvar *field-snapshot-context* nil)

(defun %note-snapshot-node (context depth)
  (when (> depth +max-log-field-depth+)
    (%resource-limit-exceeded :depth +max-log-field-depth+ depth))
  (let ((nodes (incf (%snapshot-context-nodes context))))
    (when (> nodes +max-log-field-nodes+)
      (%resource-limit-exceeded :nodes +max-log-field-nodes+ nodes))))

(defun %snapshot-active-table (context)
  "CONTEXT's EQ table of containers currently being copied, created on first
use so a field value that contains no container never allocates one."
  (or (%snapshot-context-active context)
      (setf (%snapshot-context-active context)
            (make-hash-table :test #'eq))))

(defun %call-with-active-snapshot-object (context object thunk)
  "Call THUNK while OBJECT is marked as being snapshotted under CONTEXT, so a
self-referential value is caught as a cycle instead of recursing forever."
  (let ((active (%snapshot-active-table context)))
    (when (gethash object active)
      (%invalid-fields object "field values must not contain cycles"))
    (setf (gethash object active) t)
    (unwind-protect (funcall thunk)
      (remhash object active))))

(defmacro with-snapshot-object ((context object) &body body)
  "Evaluate BODY (which deep-copies OBJECT's children) while OBJECT is marked
active under CONTEXT, so a self-referential value is caught as a cycle. Wraps
%CALL-WITH-ACTIVE-SNAPSHOT-OBJECT the way WITH-BOUNDED-OUTPUT wraps its own CPS
helper, keeping each snapshot branch free of lambda boilerplate."
  `(%call-with-active-snapshot-object ,context ,object (lambda () ,@body)))

(defun %snapshot-cons (value context depth)
  "Deep-copy the cons tree rooted at VALUE, walking its CDR spine iteratively.

Only the CARs — and a dotted tail — descend a level of DEPTH; the spine
itself stays at DEPTH. Recursing on the CDR as well, the obvious reading of
\"a cons has two children,\" would instead charge an ordinary flat list one
level of nesting per element, so a 100-element list field would be rejected
as 100 levels deep while the equivalent 100-element vector or JSON array
passed. A list's *length* is therefore bounded the way every other
collection's is — the per-collection element cap plus the shared node
budget — and DEPTH keeps meaning what the documentation says it means.

VALUE's own node was already counted by %SNAPSHOT-FIELD-VALUE; each further
spine cons counts itself. Every spine cons is marked active for the whole
walk, so a circular list is still rejected as a cycle rather than followed."
  (let ((active (%snapshot-active-table context))
        (marked nil)
        (head nil)
        (tail nil)
        (length 0))
    (unwind-protect
        (loop for current = value then (cdr current)
              do (cond
                   ((consp current)
                    (when (gethash current active)
                      (%invalid-fields current "field values must not contain cycles"))
                    (setf (gethash current active) t)
                    (push current marked)
                    (unless (eq current value)
                      (%note-snapshot-node context depth))
                    (%check-snapshot-size :array-elements (incf length)
                                          +max-log-field-array-elements+)
                    (let ((copy (cons (%snapshot-field-value (car current) context
                                                             (1+ depth))
                                      nil)))
                      (if tail (setf (cdr tail) copy) (setf head copy))
                      (setf tail copy)))
                   (t
                    ;; NIL terminates a proper list; any other atom is a dotted
                    ;; tail and is snapshotted as a value, exactly like a CAR.
                    (setf (cdr tail) (%snapshot-field-value current context (1+ depth)))
                    (return head))))
      (dolist (cons marked)
        (remhash cons active)))))

(defun-defaulted %snapshot-field-value (value &optional context (depth 0))
  (if (null value)
      nil
      (let ((context (or context *field-snapshot-context* (%make-snapshot-context))))
        (%note-snapshot-node context depth)
        (labels ((child (current)
                   (%snapshot-field-value current context (1+ depth))))
          (typecase value
            ((or json-null-marker json-false-marker) value)
            (json-object-value
             (%check-snapshot-size :array-elements (length (%json-object-members value))
                                   +max-log-field-array-elements+)
             (with-snapshot-object (context value)
               (%make-json-object
                (mapcar (lambda (pair) (cons (%copy-field-key (car pair)) (child (cdr pair))))
                        (%json-object-members value)))))
            (json-array-value
             (%check-snapshot-size :array-elements (length (%json-array-elements value))
                                   +max-log-field-array-elements+)
             (with-snapshot-object (context value)
               (%make-json-array (map 'vector #'child (%json-array-elements value)))))
            (string
             (%check-field-string-length value)
             (copy-seq value))
            (cons (%snapshot-cons value context depth))
            (array
             (%check-snapshot-size :array-elements (array-total-size value)
                                   +max-log-field-array-elements+)
             (with-snapshot-object (context value)
               (let ((copy (make-array (array-dimensions value)
                                       :element-type (array-element-type value))))
                 (dotimes (index (array-total-size value) copy)
                   (setf (row-major-aref copy index) (child (row-major-aref value index)))))))
            (hash-table
             (let ((count (hash-table-count value)))
               (%check-snapshot-size :hash-table-entries count +max-log-field-array-elements+)
               (with-snapshot-object (context value)
                 (let ((copy (make-hash-table :test (hash-table-test value) :size count)))
                   (maphash (lambda (key item) (setf (gethash (child key) copy) (child item)))
                            value)
                   copy))))
            (t value))))))

(defun %copy-field-alist (fields)
  (let ((*field-snapshot-context* (%make-snapshot-context)))
    (mapcar #'%copy-field-pair fields)))
