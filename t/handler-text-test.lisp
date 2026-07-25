;;;; t/handler-text-test.lisp
;;;
;;; text-handler wire format: one physical line per record, with untrusted
;;; tokens escaped so a log line can never be spoofed or split, and the
;;; hostile-printer guarantee (arbitrary field values never reach an
;;; unbounded PRINT-OBJECT method). Mirrors src/handler-text.lisp.
(in-package #:cl-log-kit/test)

;;; A value whose printer never terminates and counts its own invocations, so
;;; a test can prove the text handler never calls an arbitrary print-object.
(defvar *hostile-printer-call-count* 0)

(defclass hostile-text-value () ())

(defmethod print-object ((value hostile-text-value) stream)
  (declare (ignore value stream))
  (incf *hostile-printer-call-count*)
  (loop))

(describe "text wire format"
  (it "text-handler emits one physical line and escapes unsafe controls"
    (let ((output
            (render-through
              'text-handler
              (make-test-record
                :message (coerce (list #\a #\Newline (code-char #x202E)
                                       (code-char #x2066) (code-char #x200B))
                                 'string)
                :fields (list :control
                              (coerce (list (code-char 0) (code-char 127) (code-char #x2029))
                                      'string))))))
      (expect output :to-be-single-line)
      (dolist (escape '("\\n" "\\u0000" "\\u007F" "\\u2029" "\\u202E" "\\u2066" "\\u200B"))
        (expect output :to-contain-substring escape))))

  (it "text-handler never invokes arbitrary value printers"
    (let ((*hostile-printer-call-count* 0)
          (output nil)
          (finished nil)
          (thread nil))
      (setf thread
            (sb-thread:make-thread
              (lambda ()
                (setf output
                      (render-through 'text-handler
                                      (make-test-record
                                        :fields (list :hostile
                                                      (make-instance 'hostile-text-value)))))
                (setf finished t))))
      (unless (sb-thread:join-thread thread :timeout 1 :default nil)
        (sb-thread:terminate-thread thread))
      (expect finished :to-be-truthy)
      (expect (= 0 *hostile-printer-call-count*) :to-be-truthy)
      (expect output :to-contain-substring "field.\"hostile\"=\"#<object>\"")))

  (it "text wire format quotes untrusted tokens and contains special arithmetic"
    (let* ((bidi (string (code-char #x202E)))
           (output
             (render-through
               'text-handler
               (make-test-record
                 :logger-name (concatenate 'string "root level=FATAL \" \\ / " bidi)
                 :message "message level=FATAL"
                 :fields (list "key value=forged"
                               sb-ext:double-float-positive-infinity
                               :complex
                               (complex sb-ext:double-float-positive-infinity 1d0))))))
      (expect output :to-be-single-line)
      (expect output :to-contain-substring "logger=\"root level=FATAL \\\" \\\\ / \\u202E\"")
      (expect output :to-contain-substring "<non-finite-float>")
      (expect output :to-contain-substring "<non-finite-complex>"))))
