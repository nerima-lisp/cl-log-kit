;;;; src/fields.lisp
;;;
;;; The public field-construction API built on snapshot.lisp's deep-copy
;;; engine: JSON-OBJECT/JSON-ARRAY and their accessors, and PLIST-TO-ALIST,
;;; the canonical-alist conversion every log call's field plist goes
;;; through.
(in-package #:log-kit)

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
