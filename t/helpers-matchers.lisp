;;;; t/helpers-matchers.lisp
;;;
;;; Domain matchers that lift the suite's field assertions from raw
;;; (expect (string= (cdr (assoc :k fields)) "v") :to-be-truthy) plumbing up to
;;; intention-revealing (expect fields :to-have-field :k "v"). Registered
;;; through cl-weave's own EXPECT-EXTEND, so the framework gains a log-kit
;;; vocabulary without knowing anything about log-kit.
;;;
;;; Field keys are matched by log-kit's canonical rule (case-insensitive,
;;; symbol-or-string), so a spec names the field it means rather than the exact
;;; key object the library happened to store.
(in-package #:cl-log-kit/test)

(defun canonical-field-key (key)
  "Downcase KEY the way log-kit canonicalizes a field name for lookup."
  (string-downcase (etypecase key
                     (symbol (symbol-name key))
                     (string key))))

(defun field-entry (fields key)
  "The (KEY . VALUE) pair in FIELDS whose key canonicalizes to KEY, or NIL."
  (assoc (canonical-field-key key) fields
         :key #'canonical-field-key :test #'string=))

(cl-weave:expect-extend
  (:to-have-field (fields expected)
    "Pass when FIELDS holds KEY with a value EQUAL to VALUE."
    (destructuring-bind (key value) expected
      (let ((entry (field-entry fields key)))
        (values (and entry (equal (cdr entry) value) t)
                (list :present (and entry t) :value (when entry (cdr entry)))
                (list :key key :value value)))))

  (:to-have-field-matching (fields expected)
    "Pass when FIELDS holds KEY and PREDICATE is true of its value."
    (destructuring-bind (key predicate) expected
      (let ((entry (field-entry fields key)))
        (values (and entry (funcall predicate (cdr entry)) t)
                (list :present (and entry t) :value (when entry (cdr entry)))
                (list :key key :predicate predicate)))))

  (:to-lack-field (fields expected)
    "Pass when FIELDS has no entry for KEY."
    (destructuring-bind (key) expected
      (let ((entry (field-entry fields key)))
        (values (null entry)
                (list :entry entry)
                (list :absent-key key)))))

  (:to-be-single-line (output expected)
    "Pass when OUTPUT is exactly one newline-terminated physical line."
    (declare (ignore expected))
    (let ((newlines (count #\Newline output)))
      (values (= newlines 1)
              (list :newlines newlines)
              (list :newlines 1))))

  (:to-have-recorded (handler expected)
    "Pass when HANDLER (a counting-handler) has captured exactly COUNT records."
    (destructuring-bind (count) expected
      (let ((recorded (length (counting-handler-records handler))))
        (values (= recorded count)
                (list :recorded recorded)
                (list :recorded count)))))

  (:to-contain-substring (output expected)
    "Pass when the string OUTPUT contains SUBSTRING literally (as by SEARCH)."
    (destructuring-bind (substring) expected
      (values (and (search substring output) t)
              (list :output output)
              (list :substring substring)))))
