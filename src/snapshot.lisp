;;;; src/snapshot.lisp
;;;
;;; The structured-field value model (explicit JSON markers, objects, arrays)
;;; and the deep, bounded, cycle-checked snapshot that copies every field
;;; value before it enters an immutable log record. This is what makes a
;;; record a true point-in-time snapshot the caller can no longer mutate.
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

(defstruct (json-null-marker (:constructor %make-json-null)))
(defstruct (json-false-marker (:constructor %make-json-false)))

(defparameter +json-null+ (%make-json-null)
  "The sentinel a field value must be EQ to for the JSON encoder to render it
as a literal JSON null, distinct from Lisp NIL (which JSON handlers already
have their own meaning for).")
(defparameter +json-false+ (%make-json-false)
  "The sentinel a field value must be EQ to for the JSON encoder to render it
as a literal JSON false, distinct from Lisp NIL.")

(defun json-null-p (value)
  "True when VALUE is the +JSON-NULL+ sentinel."
  (json-null-marker-p value))

(defun json-false-p (value)
  "True when VALUE is the +JSON-FALSE+ sentinel."
  (json-false-marker-p value))

(defstruct (json-object-value
            (:constructor %make-json-object (members))
            (:predicate json-object-p))
  (members nil :type list :read-only t))

(setf (documentation 'json-object-p 'function)
      "True when VALUE is a JSON object wrapper created by JSON-OBJECT.")

(defstruct (json-array-value
            (:constructor %make-json-array (elements))
            (:predicate json-array-p))
  (elements #() :type vector :read-only t))

(setf (documentation 'json-array-p 'function)
      "True when VALUE is a JSON array wrapper created by JSON-ARRAY.")

(defun %json-object-members (object)
  (json-object-value-members object))

(defun %json-array-elements (array)
  (json-array-value-elements array))

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

(defun %call-with-active-snapshot-object (context object thunk)
  "Call THUNK while OBJECT is marked as being snapshotted under CONTEXT, so a
self-referential value is caught as a cycle instead of recursing forever."
  (let ((active (or (%snapshot-context-active context)
                     (setf (%snapshot-context-active context)
                           (make-hash-table :test #'eq)))))
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

(defun %snapshot-field-value (value &optional context (depth (%constant-default 0)))
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
            (cons
             (with-snapshot-object (context value)
               (cons (child (car value)) (child (cdr value)))))
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

(defun %validated-object-members (members)
  (%bounded-proper-list-length members +max-log-field-array-elements+ :array-elements
                               "JSON object members must be a finite proper alist")
  (let ((*field-snapshot-context* (%make-snapshot-context))
        (seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (pair members (nreverse result))
      (unless (consp pair)
        (%invalid-fields members "each JSON object member must be a cons pair"))
      (let ((key (car pair)))
        (%validate-field-key key members)
        (%check-duplicate-canonical-key (%canonical-field-name key) seen members
                                        "duplicate canonical JSON object member")
        (push (%copy-field-pair pair) result)))))

(defun json-object (members)
  "Wrap MEMBERS — an alist of (KEY . VALUE) cons pairs with symbol or string
keys and no duplicate canonical key — as a JSON object field value. Signals
INVALID-LOG-FIELDS on a malformed member or a duplicate canonical key."
  (%make-json-object (%validated-object-members members)))

(defun json-array (elements)
  "Wrap ELEMENTS — a proper list or vector — as a JSON array field value.
Every element is defensively snapshotted the same way a plain field value
is."
  (if (vectorp elements)
      (%check-snapshot-size :array-elements (length elements) +max-log-field-array-elements+)
      (%bounded-proper-list-length elements +max-log-field-array-elements+ :array-elements
                                   "JSON array elements must be a finite proper list or vector"))
  (let ((*field-snapshot-context* (%make-snapshot-context)))
    (%make-json-array (map 'vector #'%snapshot-field-value elements))))

(defun json-object-members (object)
  "Return a fresh copy of OBJECT's (KEY . VALUE) member alist."
  (check-type object json-object-value)
  (let ((*field-snapshot-context* (%make-snapshot-context)))
    (mapcar #'%copy-field-pair (%json-object-members object))))

(defun json-array-elements (array)
  "Return a fresh copy of ARRAY's element vector."
  (check-type array json-array-value)
  (let ((*field-snapshot-context* (%make-snapshot-context)))
    (map 'vector #'%snapshot-field-value (%json-array-elements array))))

(defun plist-to-alist (plist)
  "Convert PLIST (a property list of field key/value pairs) to a canonical
alist: keys are validated and defensively copied, values are recursively
snapshotted, and only the first pair for each canonical key is kept."
  (%bounded-proper-list-length plist (* 2 +max-log-field-array-elements+) :array-elements
                               "field plist must be a finite proper list")
  (let ((*field-snapshot-context* (%make-snapshot-context))
        (seen (make-hash-table :test #'equal))
        (result nil))
    (loop for tail on plist by #'cddr
          do (when (null (cdr tail))
               (%invalid-fields plist "field plist must contain an even number of elements"))
             (let* ((key (car tail))
                    (value (cadr tail)))
               (%validate-field-key key plist)
               (%check-duplicate-canonical-key (%canonical-field-name key) seen plist
                                               "duplicate canonical field name")
               (push (cons (%copy-field-key key) (%snapshot-field-value value)) result))
          finally (return (nreverse result)))))

(defun %copy-field-alist (fields)
  (let ((*field-snapshot-context* (%make-snapshot-context)))
    (mapcar #'%copy-field-pair fields)))
