;;;; src/encoding.lisp
;;;
;;; Low-level, allocation-conscious encoding primitives shared by
;;; handler-text.lisp and handler-json.lisp: base-10 integer digits, a
;;; \uXXXX Unicode escape, the downcased-keyword-name cache, and the
;;; symbol-to-field-string rule. Pure data-rendering helpers with no
;;; dependency on the handler protocol or stream lifecycle in handler.lisp.
(in-package #:log-kit)

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
