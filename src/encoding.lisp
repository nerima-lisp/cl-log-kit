(in-package #:log-kit)

;;; Immutable copy-on-write cache for downcased keyword names. Hits are
;;; lock-free; misses copy the table under the cache lock before publishing it.
(sb-ext:defglobal **keyword-name-cache** (make-hash-table :test #'eq))

;;; Shared low-level escape used by both the text and JSON encoders: render a
;;; code point as a \uXXXX escape. It lives in the backbone so neither
;;; concrete encoder file has to depend on the other.
(defun %write-unicode-escape (code stream)
  (format stream "\\u~4,'0X" code))

;;; Write fixnums directly in base 10 to avoid printer overhead and allocations.
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

(defvar *keyword-name-cache-lock*
  (cl-concurrent-kit:make-lock :name "cl-log-kit keyword name cache"))

(defun %cached-keyword-name (keyword)
  "Return KEYWORD's downcased symbol name, interning it on first use so later
calls reuse the same string instead of reallocating it."
  (or (gethash keyword **keyword-name-cache**)
      (cl-concurrent-kit:with-lock-held (*keyword-name-cache-lock*)
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
