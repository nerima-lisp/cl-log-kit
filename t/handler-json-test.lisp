;;;; t/handler-json-test.lisp
;;;
;;; json-handler wire format: one strict RFC 8259 JSON object per line,
;;; validated up front so a partially written object can never reach the
;;; stream. Mirrors src/handler-json.lisp.
(in-package #:cl-log-kit/test)

(describe "json wire format"
  (it "json-handler nests explicit objects and arrays"
    (let ((output
            (render-through
              'json-handler
              (make-test-record
                :fields (list :payload
                              (json-object
                                (list (cons :enabled +json-false+)
                                      (cons :missing +json-null+)
                                      (cons :items (json-array (vector 1 "two" t))))))))))
      (expect output :to-contain-substring "\"payload\":{\"enabled\":false,\"missing\":null,\"items\":[1,\"two\",true]}")))

  (it "json-handler does not infer JSON containers from ordinary lists"
    (dolist (value (list 1/2 (complex 1 2) (list 1 2) (make-hash-table)
                         sb-ext:double-float-positive-infinity))
      (signals unsupported-json-value (render-json-value value))))

  (it "json-handler rejects Unicode surrogate code points"
    (let ((surrogate (code-char #xD800)))
      (when surrogate
        (signals unsupported-json-value (render-json-value (string surrogate))))))

  (it "json-handler output parses back to the expected structure"
    ;; Assert the emitted line is well-formed JSON by parsing it with an
    ;; independent nerima-lisp parser (cl-json-kit) and checking the decoded
    ;; structure, rather than only matching substrings — this catches a
    ;; malformed object (stray comma, unquoted key) a SEARCH would miss.
    (let* ((output (render-through
                     'json-handler
                     (make-test-record :message "hi" :timestamp 42
                                       :fields (list :count 7 :name "abc" :ok t))))
           (parsed (json-kit:parse output :object-type :alist)))
      (flet ((member-of (object key) (cdr (assoc key object :test #'string=))))
        (expect (member-of parsed "message") :to-equal "hi")
        (expect (member-of parsed "level") :to-equal "INFO")
        (expect (member-of parsed "logger") :to-equal "root")
        (expect (member-of parsed "time") :to-equal 42)
        (let ((fields (member-of parsed "fields")))
          (expect (member-of fields "count") :to-equal 7)
          (expect (member-of fields "name") :to-equal "abc")
          (expect (member-of fields "ok") :to-be t)))))

  (it "json-handler keeps reserved-looking fields nested"
    (let ((output
            (render-through
              'json-handler
              (make-test-record :message "outer"
                                :fields (list :message "inner" :timestamp 7)))))
      (expect output :to-contain-substring "\"message\":\"outer\"")
      (expect output :to-contain-substring "\"fields\":{\"message\":\"inner\",\"timestamp\":7}")))

  (it "emits finite floats as strict RFC 8259 numbers"
    (labels ((render (value)
               (with-output-to-string (stream)
                 (log-kit::%write-json-float value stream)))
             (strict-number-p (text)
               (and (> (length text) 0)
                    (not (find #\Space text))
                    (not (find #\d text :test #'char-equal))
                    (not (char= #\. (char text (1- (length text)))))
                    (every (lambda (character)
                             (or (digit-char-p character)
                                 (find character "+-.e" :test #'char-equal)))
                           text))))
      (dolist (value (list 0.0s0 -0.0s0 0.0f0 -0.0f0 0.0d0 -0.0d0 0.0l0 -0.0l0
                           least-positive-normalized-short-float most-positive-short-float
                           least-positive-normalized-single-float most-positive-single-float
                           least-positive-normalized-double-float most-positive-double-float
                           least-positive-normalized-long-float most-positive-long-float
                           1.0d200))
        (expect (strict-number-p (render value)) :to-be-truthy))
      (expect (string= "-0.0" (render -0.0d0)) :to-be-truthy)
      (expect (string= "0.0" (render 0.0d0)) :to-be-truthy)
      (expect (find #\e (render 1.0d200) :test #'char-equal) :to-be-truthy))))
