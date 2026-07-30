;;;; src/macro-utils.lisp
;;;
;;; Macro-authoring utilities shared by every DEFUN-DEFAULTED/
;;; DEFMETHOD-DEFAULTED call site across the codebase: CHECK-TYPES for
;;; multi-value type validation, and the %CONSTANT-DEFAULT wrapper (plus its
;;; lambda-list rewriter) that keeps sb-cover crediting an omitted-keyword
;;; default as executed code instead of a permanently "not run" literal.
(in-package #:log-kit)

(defmacro check-types (&body clauses)
  "Run CHECK-TYPE on each (VALUE TYPE) pair in CLAUSES, in argument order,
so a constructor stating several CHECK-TYPE guards writes the value/type
table once instead of one CHECK-TYPE form per line."
  `(progn ,@(loop for (value type) in clauses collect `(check-type ,value ,type))))

(defmacro document-readers (&body clauses)
  "Set (DOCUMENTATION READER 'FUNCTION) for each (READER DOCSTRING) pair in
CLAUSES. DEFINE-CONDITION's and DEFSTRUCT's per-slot :DOCUMENTATION only
reaches MOP slot introspection, not (DOCUMENTATION #'READER 'FUNCTION); this
is what makes the generated reader functions answer DOCUMENTATION too,
without repeating one SETF form per reader."
  `(progn ,@(loop for (reader docstring) in clauses
                  collect `(setf (documentation ',reader 'function) ,docstring))))

(defun %constant-default (value)
  "Return VALUE unchanged. Used as a &KEY/&OPTIONAL default-value form in
place of a bare literal or DEFCONSTANT reference: SBCL constant-folds a
literal default at every call site that omits the keyword, so the source
position of the default form itself is never re-evaluated at runtime and
sb-cover reports it \"not executed\" even when the omitted-keyword path is
exercised. A default of (%CONSTANT-DEFAULT literal) is an ordinary,
non-inlined function call SBCL cannot fold away, so sb-cover credits it the
same way it credits any other executed form — the same tradeoff already
made project-wide when the DECLAIM INLINE on LEVEL</LEVEL<= was removed.
DEFUN-DEFAULTED/DEFMETHOD-DEFAULTED below apply this wrapper automatically,
so callers write the plain literal and never this function's name."
  value)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun %wrap-defaulted-lambda-list (lambda-list)
    "Copy LAMBDA-LIST (an ordinary or specialized lambda list) with every
&OPTIONAL/&KEY entry of the form (VAR DEFAULT) or (VAR DEFAULT SUPPLIED-P)
rewritten so DEFAULT is wrapped in %CONSTANT-DEFAULT. A required parameter,
a bare (no-default) &OPTIONAL variable, and everything at or after &REST/
&AUX/&ALLOW-OTHER-KEYS pass through unchanged."
    (let ((section nil))
      (mapcar (lambda (item)
                (cond
                  ((member item '(&optional &key &rest &aux &allow-other-keys))
                   (setf section item)
                   item)
                  ((and (member section '(&optional &key)) (consp item))
                   (list* (first item) `(%constant-default ,(second item)) (cddr item)))
                  (t item)))
              lambda-list))))

(defmacro defun-defaulted (name lambda-list &body body)
  "Like DEFUN, but every &OPTIONAL/&KEY default-value form in LAMBDA-LIST is
implicitly wrapped in %CONSTANT-DEFAULT: write the plain literal at each
default, not the wrapper call."
  `(defun ,name ,(%wrap-defaulted-lambda-list lambda-list) ,@body))

(defmacro defmethod-defaulted (name &rest qualifiers-lambda-list-and-body)
  "Like DEFMETHOD, but every &OPTIONAL/&KEY default-value form in the
method's lambda list is implicitly wrapped in %CONSTANT-DEFAULT, the same as
DEFUN-DEFAULTED. Accepts the same optional method qualifiers (:AROUND,
:BEFORE, :AFTER, ...) as DEFMETHOD, ahead of the specialized lambda list."
  (let* ((lambda-list-position (position-if #'listp qualifiers-lambda-list-and-body))
         (qualifiers (subseq qualifiers-lambda-list-and-body 0 lambda-list-position))
         (lambda-list (nth lambda-list-position qualifiers-lambda-list-and-body))
         (body (nthcdr (1+ lambda-list-position) qualifiers-lambda-list-and-body)))
    `(defmethod ,name ,@qualifiers ,(%wrap-defaulted-lambda-list lambda-list) ,@body)))
