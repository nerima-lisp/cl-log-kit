;;;; src/json-values.lisp
;;;
;;; The explicit JSON value model: the null/false sentinels and the object/
;;; array wrapper structs, with the predicates and member accessors built on
;;; them. This is pure data — no algorithm of its own — so both
;;; snapshot.lisp's recursive deep-copier and json-encoding.lisp's writer/
;;; validator depend on it.
(in-package #:log-kit)

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

(document-readers
  (json-object-p "True when VALUE is a JSON object wrapper created by JSON-OBJECT."))

(defstruct (json-array-value
            (:constructor %make-json-array (elements))
            (:predicate json-array-p))
  (elements #() :type vector :read-only t))

(document-readers
  (json-array-p "True when VALUE is a JSON array wrapper created by JSON-ARRAY."))

(defun %json-object-members (object)
  (json-object-value-members object))

(defun %json-array-elements (array)
  (json-array-value-elements array))
