;;;; t/handler-test.lisp

(in-package #:cl-log-kit/test)

(defun %make-record (&key (level +level-info+) (message "hello")
                        (timestamp 42) (fields nil) (logger-name "root"))
  (make-log-record :level level :message message :timestamp timestamp
                    :fields fields :logger-name logger-name))

;;; Regression test for the cl-cc bug: *LOG-JSON-OUTPUT* being nil caused
;;; %LOG-EMIT-TEXT to print once, and then a second, unrelated code path
;;; printed the very same message again -- two lines for one log call.
;;; HANDLE-LOG-RECORD's contract is "exactly one output operation", so this
;;; test asserts the emitted text is exactly one line.
(it "text-handler emits exactly one line per record (no double-print regression)"
  (let* ((output (with-output-to-string (stream)
                    (let ((handler (make-instance 'text-handler :stream stream)))
                      (handle-log-record handler (%make-record :message "started")))))
         (newline-count (count #\Newline output)))
    (expect (= newline-count 1) :to-be-truthy)
    (expect (not (null (search "[INFO] started" output))) :to-be-truthy)))

(it "text-handler renders fields as key=value pairs"
  (let ((output (with-output-to-string (stream)
                  (let ((handler (make-instance 'text-handler :stream stream)))
                    (handle-log-record handler (%make-record :message "req"
                                                              :fields '((:port . 8080) (:ok . t))))))))
    (expect (not (null (search "req port=8080 ok=T" output))) :to-be-truthy)))

;;; Same regression coverage as above, for the JSON handler.
(it "json-handler emits exactly one line per record (no double-print regression)"
  (let* ((output (with-output-to-string (stream)
                    (let ((handler (make-instance 'json-handler :stream stream)))
                      (handle-log-record handler (%make-record :message "started")))))
         (newline-count (count #\Newline output)))
    (expect (= newline-count 1) :to-be-truthy)))

(it "json-handler output is a single balanced JSON object with the expected keys"
  (let ((output (with-output-to-string (stream)
                  (let ((handler (make-instance 'json-handler :stream stream)))
                    (handle-log-record handler (%make-record :level +level-warn+
                                                              :message "disk low"
                                                              :timestamp 12345))))))
    (expect (char= (char output 0) #\{) :to-be-truthy)
    (expect (= (count #\{ output) (count #\} output)) :to-be-truthy)
    (expect (not (null (search "\"level\":\"WARN\"" output))) :to-be-truthy)
    (expect (not (null (search "\"message\":\"disk low\"" output))) :to-be-truthy)
    (expect (not (null (search "\"timestamp\":12345" output))) :to-be-truthy)))

(it "json-handler escapes quotes, backslashes, and newlines in the message"
  (let ((output (with-output-to-string (stream)
                  (let ((handler (make-instance 'json-handler :stream stream)))
                    (handle-log-record handler
                                        (%make-record :message (format nil "line1~%line2 \"quoted\" back\\slash")))))))
    ;; The escaped payload must stay on a single output line...
    (expect (= (count #\Newline output) 1) :to-be-truthy)
    ;; ...while the escape sequences for each special character are present.
    (expect (not (null (search "line1\\nline2" output))) :to-be-truthy)
    (expect (not (null (search "\\\"quoted\\\"" output))) :to-be-truthy)
    (expect (not (null (search "back\\\\slash" output))) :to-be-truthy)))

(it "json-handler includes field values in the output"
  (let ((output (with-output-to-string (stream)
                  (let ((handler (make-instance 'json-handler :stream stream)))
                    (handle-log-record handler (%make-record :message "req"
                                                              :fields '((:port . 8080))))))))
    (expect (not (null (search "\"port\":8080" output))) :to-be-truthy)))
