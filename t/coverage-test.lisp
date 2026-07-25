;;;; t/coverage-test.lisp
;;;
;;; Boundary and edge-case specs that exercise the rarely-taken branches:
;;; every wire-format value type, level-name for all ranks, malformed
;;; structured fields, default span sources, and lifecycle guard rails. These
;;; close the branch-coverage gaps the behavioural specs leave open.
(in-package #:cl-log-kit/test)

(describe "edge cases"
  (describe "level names"
    (it-each ((0 "DEBUG")
              (10 "INFO")
              (20 "WARN")
              (30 "ERROR")
              (40 "FATAL")
              (99 "99"))
        "renders rank ~A as ~A"
        (rank name)
      (let ((output (render-through 'text-handler (make-test-record :level rank))))
        (expect output :to-contain-substring (format nil "level=~A" name))))

    (it "level< and level<= are callable out of line"
      (expect (funcall #'level< 1 2) :to-be-truthy)
      (expect (not (funcall #'level< 2 2)) :to-be-truthy)
      (expect (funcall #'level<= 2 2) :to-be-truthy)
      (expect (not (funcall #'level<= 3 2)) :to-be-truthy))

    (it "renders the canonical debug level name"
      (expect (level-name +level-debug+) :to-match-inline-snapshot "\"DEBUG\"")))

  (describe "text value types"
    (it "renders characters, ratios, finite complexes, and keywords"
      (let ((output (render-through
                      'text-handler
                      (make-test-record
                        :message (string #\Return)
                        :fields (list :char #\A
                                      :ratio 3/4
                                      :complex #C(1.0d0 -2.0d0)
                                      :kw :active)))))
        (expect output :to-contain-substring "\\r")
        (expect output :to-contain-substring "field.\"char\"=\"A\"")
        (expect output :to-contain-substring "field.\"ratio\"=\"3/4\"")
        (expect output :to-contain-substring "i)")
        (expect output :to-contain-substring "field.\"kw\"=\"active\"")))

    (it "escapes a zero-width-no-break-space (BOM) as a spoof character"
      (let ((output (render-through
                      'text-handler
                      (make-test-record :fields (list :bom (string (code-char #xFEFF)))))))
        (expect output :to-contain-substring "\\uFEFF")))

    (it "escapes U+2028/U+2029 line separators and a lone surrogate code point"
      (dolist (spec (list (cons #x2028 "\\u2028") (cons #x2029 "\\u2029") (cons #xD800 "\\uD800")))
        (let ((output (render-through
                        'text-handler
                        (make-test-record :fields (list :v (string (code-char (car spec))))))))
          (expect output :to-contain-substring (cdr spec)))))

    (it "passes an ordinary non-ASCII character through unescaped"
      ;; A plain accented letter is non-printable-ASCII but matches none of
      ;; the control/surrogate/spoof escape conditions, so it must render
      ;; as-is rather than as a \uXXXX escape.
      (let ((output (render-through
                      'text-handler
                      (make-test-record :fields (list :v (string (code-char #xE9)))))))
        (expect output :to-contain-substring (string (code-char #xE9)))
        (expect (not (search "\\u00E9" output :test #'char-equal)) :to-be-truthy)))

    (it "renders a non-simple string value through the same escaping path"
      ;; Every field value is normally COPY-SEQ'd into a simple string by the
      ;; snapshot layer before a handler ever sees it, so this calls the
      ;; encoder directly to exercise its own non-simple-string branch.
      (let* ((source "needs escaping \" and plain")
             (non-simple (make-array (length source) :element-type 'character
                                                      :adjustable t :fill-pointer (length source)
                                                      :initial-contents source))
             (output (with-output-to-string (stream)
                       (log-kit::%write-text-value non-simple stream))))
        (expect output :to-contain-substring "\\\"")
        (expect output :to-contain-substring "plain")))

    (it "writes a bignum field value via the printer fallback"
      (let ((bignum (expt 2 100)))
        (expect (render-through 'text-handler (make-test-record :fields (list :big bignum)))
                :to-contain-substring (princ-to-string bignum)))))

  (describe "json value types"
    (it "escapes control and reserved characters in json strings"
      (let ((output (render-through
                      'json-handler
                      (make-test-record
                        :fields (list :s (coerce (list #\" #\\ #\Backspace #\Page
                                                       #\Newline #\Return #\Tab
                                                       (code-char 1) (code-char 127))
                                                 'string))))))
        (dolist (escape '("\\\"" "\\\\" "\\b" "\\f" "\\n" "\\r" "\\t" "\\u0001" "\\u007F"))
          (expect output :to-contain-substring escape))))

    (it "passes an ordinary non-ASCII character through unescaped"
      (let ((output (render-through
                      'json-handler
                      (make-test-record :fields (list :v (string (code-char #xE9)))))))
        (expect output :to-contain-substring (string (code-char #xE9)))
        (expect (not (search "\\u00E9" output :test #'char-equal)) :to-be-truthy)))

    (it "encodes bare integer, float, symbol, and boolean field values"
      (let ((output (render-through
                      'json-handler
                      (make-test-record :fields (list :int 7 :flt 1.5d0
                                                      :sym :hello :yes t)))))
        (expect output :to-contain-substring "\"int\":7")
        (expect output :to-contain-substring "\"flt\":1.5")
        (expect output :to-contain-substring "\"sym\":\"hello\"")
        (expect output :to-contain-substring "\"yes\":true")))

    (it "rejects non-finite json floats"
      (signals unsupported-json-value (render-json-value sb-ext:double-float-positive-infinity)))

    (it "renders a non-keyword symbol used as a raw json field key"
      (let ((output (render-through 'json-handler
                                    (make-test-record :fields (list 'plain-key "v")))))
        (expect output :to-contain-substring "\"plain-key\":\"v\"")))

    (it "renders a non-simple json string through the same validation and write path"
      ;; As above: bypass the snapshot layer's COPY-SEQ so the non-simple
      ;; branch in both %VALIDATE-JSON-STRING and %WRITE-JSON-STRING runs.
      (let* ((source "needs escaping \" and plain")
             (non-simple (make-array (length source) :element-type 'character
                                                      :adjustable t :fill-pointer (length source)
                                                      :initial-contents source)))
        (expect (log-kit::%validate-json-string non-simple) :to-be-truthy)
        (let ((output (with-output-to-string (stream)
                        (log-kit::%write-json-string non-simple stream))))
          (expect output :to-contain-substring "\\\"")
          (expect output :to-contain-substring "plain"))))

    (it "writes a bignum field value via the printer fallback"
      (let ((bignum (expt 2 100)))
        (expect (render-through 'json-handler (make-test-record :fields (list :big bignum)))
                :to-contain-substring (princ-to-string bignum)))))

  (describe "structured field validation"
    (it "snapshots multi-dimensional arrays by value"
      (let* ((grid (make-array '(2 2) :initial-contents '((1 2) (3 4))))
             (record (make-log-record :fields (list :grid grid)))
             (snapshot (cdr (assoc :grid (log-record-fields record)))))
        (expect (equal (array-dimensions snapshot) '(2 2)) :to-be-truthy)
        (expect (= (aref snapshot 1 1) 4) :to-be-truthy)
        (setf (aref grid 1 1) 99)
        (expect (= (aref snapshot 1 1) 4) :to-be-truthy)))

    (it "rejects malformed json object members"
      (dolist (thunk (list (lambda () (json-object (cons :a 1)))
                           (lambda () (json-object '(:not-a-pair)))
                           (lambda () (json-object (list (cons :a 1) (cons "A" 2))))
                           (lambda () (json-object (list (cons 5 1))))))
        (expect thunk :to-throw 'invalid-log-fields)))

    (it "rejects json arrays that are neither list nor vector"
      (signals invalid-log-fields (json-array 5)))

    (it "rejects field keys that are neither symbol nor string"
      (signals invalid-log-fields (plist-to-alist (list 5 "v")))))

  (describe "logger name validation"
    (it "logger-child rejects malformed name elements"
      (dolist (bad '("" ".lead" "trail." "a..b"))
        (signals type-error (logger-child (make-logger) bad))))

    (it "%validate-logger-initargs rejects an improper initarg list"
      (signals program-error (log-kit::%validate-logger-initargs (list* :name "x" :level))))

    (it "set-default-logger installs the global default"
      (let ((saved *default-logger*))
        (unwind-protect
            (let ((logger (make-logger)))
              (expect (eq (set-default-logger logger) logger) :to-be-truthy)
              (expect (eq *default-logger* logger) :to-be-truthy))
          (set-default-logger saved))))

    (it "log-default logs at an explicit level through the default logger"
      (multiple-value-bind (logger fetch) (capturing-logger :level +level-debug+)
        (let ((*default-logger* logger))
          (log-default +level-warn+ "generic default")
          (expect (funcall fetch) :to-contain-substring "generic default")))))

  (describe "default span sources"
    (it "uses the monotonic clock and generated ids by default"
      (multiple-value-bind (logger handler) (counting-logger :level +level-debug+)
        (with-log-span (logger "default-span")
          :ok)
        (let* ((records (counting-handler-in-order handler))
               (start (first records))
               (end (second records)))
          (expect (= (length records) 2) :to-be-truthy)
          (expect (log-record-fields start) :to-have-field-matching :span-id #'stringp)
          (expect (log-record-fields end) :to-have-field-matching :span-duration #'realp)))))

  (describe "condition fields"
    (it "condition-fields renders a condition and captures a backtrace on request"
      (let ((fields (condition-fields (make-condition 'api-broken-condition)
                                      :capture-backtrace t :backtrace-limit 256)))
        (expect (string= (getf fields :condition-type) "api-broken-condition") :to-be-truthy)
        (expect (stringp (getf fields :backtrace)) :to-be-truthy)))

    (it "condition-fields without a backtrace matches its recorded shape"
      (expect (condition-fields (make-condition 'invalid-log-fields :value 5 :reason "bad"))
              :to-match-inline-snapshot
              "(:condition-type \"invalid-log-fields\" :condition-message \"<condition invalid-log-fields>\")"))

    (it "renders a condition object supplied as an explicit backtrace"
      (multiple-value-bind (logger handler) (counting-logger)
        (log-condition logger +level-error+ (make-condition 'api-broken-condition)
                       :backtrace (make-condition 'api-broken-condition))
        (expect (latest-fields handler) :to-have-field-matching :backtrace #'stringp))))

  (describe "lifecycle guard rails"
    (it "validates the multi-handler error policy"
      (signals type-error (make-multi-handler nil :error-policy :bogus))
      (signals type-error
        (make-multi-handler nil :error-policy :callback :error-callback nil)))

    (it "rejects non-boolean auto-flush and owns-stream"
      (let ((stream (make-string-output-stream)))
        (signals type-error (make-instance 'text-handler :stream stream :auto-flush :yes))
        (signals type-error (make-instance 'text-handler :stream stream :owns-stream :yes))))

    (it "rejects closing a composite handler from within its own operation"
      (let (multi)
        (setf multi (make-multi-handler
                      (list (make-function-handler
                              (lambda (record)
                                (declare (ignore record))
                                (signals handler-lifecycle-error (close-handler multi)))))))
        (handle-log-record multi (make-log-record))
        (close-handler multi)))

    (it "closing a second owner of an already-closed stream is idempotent"
      (let* ((stream (make-string-output-stream))
             (a (make-instance 'text-handler :stream stream :owns-stream t))
             (b (make-instance 'text-handler :stream stream :owns-stream t)))
        (close-handler a)
        (expect (not (open-stream-p stream)) :to-be-truthy)
        (close-handler b)
        (expect (not (handler-open-p b)) :to-be-truthy)))

    (it "rejects a non-stream handler stream"
      (signals type-error (make-instance 'text-handler :stream 5)))))

(describe "condition and value branch closers"
  (it "condition reports render their value and reason"
    (expect (princ-to-string
                          (make-condition 'invalid-log-fields :value 5 :reason "bad")) :to-contain-substring "5")
    (expect (princ-to-string
                                    (make-condition 'invalid-log-fields
                                                    :value (make-hash-table) :reason "bad")) :to-contain-substring "unprintable")
    (expect (princ-to-string (make-condition 'unsupported-json-value :value 5)) :to-contain-substring "Unsupported JSON value")
    (expect (princ-to-string (make-condition 'log-resource-limit-exceeded
                                                     :resource :nodes :limit 1 :actual 2)) :to-contain-substring "resource limit"))

  (it "emit-log skips a filtered level"
    (multiple-value-bind (logger handler) (counting-logger :level +level-error+)
      (expect (null (emit-log logger +level-info+ "filtered")) :to-be-truthy)
      (expect handler :to-have-recorded 0)))

  (it "flushes an open function handler and reports null-handler openness"
    (let ((flushed 0))
      (let ((handler (make-function-handler (lambda (record) (declare (ignore record)))
                                            :flush-function (lambda () (incf flushed)))))
        (flush-handler handler)
        (expect (= flushed 1) :to-be-truthy)))
    (expect (handler-open-p (make-null-handler)) :to-be-truthy))

  (it "the base handler class provides trivial default flush and close methods"
    (let ((handler (make-null-handler)))
      (expect (eq (flush-handler handler) handler) :to-be-truthy)
      (expect (eq (close-handler handler) handler) :to-be-truthy)))

  (it "make-text-handler and make-json-handler default every keyword argument"
    (let ((*standard-output* (make-string-output-stream)))
      (dolist (constructor (list #'make-text-handler #'make-json-handler))
        (let ((handler (funcall constructor)))
          (expect (handler-open-p handler) :to-be-truthy)
          (handle-log-record handler (make-test-record))))
      (expect (plusp (length (get-output-stream-string *standard-output*))) :to-be-truthy)))

  (it "rejects condition output limits above the maximum"
    (signals log-resource-limit-exceeded
      (condition-fields (make-condition 'api-broken-condition)
                        :message-limit (1+ log-kit::+max-log-field-string-length+))))

  (it "snapshots a populated hash table by value"
    (let ((source (make-hash-table :test 'equal)))
      (setf (gethash "a" source) 1
            (gethash "b" source) 2)
      (let* ((record (make-log-record :fields (list :table source)))
             (snapshot (cdr (assoc :table (log-record-fields record)))))
        (expect (= (hash-table-count snapshot) 2) :to-be-truthy)
        (expect (= (gethash "a" snapshot) 1) :to-be-truthy)
        (setf (gethash "a" source) 99)
        (expect (= (gethash "a" snapshot) 1) :to-be-truthy))))

  (it "renders finite floats and non-keyword symbols as text"
    (let ((output (render-through 'text-handler
                                  (make-test-record :fields (list :flt 2.5d0 :sym 'plain-symbol)))))
      (expect output :to-contain-substring "2.5")
      (expect output :to-contain-substring "PLAIN-SYMBOL")))

  (it "encodes non-keyword symbols and rejects non-finite json floats directly"
    (let ((output (render-through 'json-handler (make-test-record :fields (list :sym 'plain)))))
      (expect output :to-contain-substring "\"sym\":\"PLAIN\""))
    (signals unsupported-json-value
      (with-output-to-string (stream)
        (log-kit::%write-json-float sb-ext:double-float-positive-infinity stream)))
    (let ((nan (sb-int:with-float-traps-masked (:invalid)
                 (- sb-ext:double-float-positive-infinity
                    sb-ext:double-float-positive-infinity))))
      (signals unsupported-json-value (render-json-value nan))))

  (it "multi-handler rejects an improper or duplicated handler list"
    (signals invalid-log-fields (make-multi-handler (cons (make-null-handler) 2)))
    (let ((handler (make-null-handler)))
      (signals program-error (make-multi-handler (list handler handler)))))

  (it "multi-handler rejects a circular handler list"
    (let ((cycle (list (make-null-handler))))
      (setf (cdr cycle) cycle)
      (signals invalid-log-fields (make-multi-handler cycle))))

  (it "multi-handler rejects a dotted handler list with an even-length proper prefix"
    (signals invalid-log-fields
      (make-multi-handler (list* (make-null-handler) (make-null-handler) 3))))

  (it "renders a gaussian-integer complex as text"
    (let ((output (render-through 'text-handler
                                  (make-test-record :fields (list :z #C(1 2))))))
      (expect output :to-contain-substring "i)")))

  (it "json-handler renders a raw string field key"
    (let ((output (render-through 'json-handler
                                  (make-test-record :fields (list "custom-key" "value")))))
      (expect output :to-contain-substring "\"custom-key\":\"value\"")))

  (it "%write-json-value falls back to unsupported-json-value for raw unsupported types"
    (dolist (value (list (list 1 2) (make-hash-table) 1/2))
      (expect (lambda () (with-output-to-string (stream) (log-kit::%write-json-value value stream)))
              :to-throw 'unsupported-json-value))))
