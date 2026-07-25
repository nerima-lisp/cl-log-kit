;;;; t/condition-logging-test.lisp
;;;
;;; LOG-CONDITION's lazy, bounded rendering of conditions into fields, and the
;;; bounded-output CPS helper it is built on. Mirrors src/condition-logging.lisp.
(in-package #:cl-log-kit/test)

;;; A condition whose report itself errors, to prove reports run only on
;;; demand and failures degrade gracefully.
(define-condition api-broken-condition (error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition stream))
             (error "broken report"))))

;;; A condition whose report is huge and counts its invocations, to bound
;;; opt-in report rendering.
(defvar *condition-report-count* 0)

(define-condition large-counting-report (error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (incf *condition-report-count*)
             (loop repeat 1000000 do (write-char #\x stream)))))

(describe "condition logging"
  (it "guards condition reports and evaluates conditions lazily"
    (multiple-value-bind (filtered handler) (counting-logger :level +level-error+)
      (let ((enabled (derive-logger filtered :level +level-debug+))
            (evaluations 0))
        (log-condition filtered +level-info+
                       (progn (incf evaluations) (make-condition 'api-broken-condition)))
        (expect (= evaluations 0) :to-be-truthy)
        (log-condition enabled +level-error+
                       (progn (incf evaluations) (make-condition 'api-broken-condition))
                       :backtrace "explicit trace" :backtrace-limit 8)
        (expect (= evaluations 1) :to-be-truthy)
        (let ((fields (latest-fields handler)))
          (expect fields :to-have-field :condition-message "<condition api-broken-condition>")
          (expect fields :to-have-field :backtrace "explicit"))
        (log-condition enabled +level-error+
                       (make-condition 'api-broken-condition) :render-report t)
        (expect (latest-fields handler)
                :to-have-field :condition-message "<condition report failed>")
        (log-condition enabled +level-error+
                       (make-condition 'api-broken-condition) :message-limit 4)
        (expect (latest-fields handler) :to-have-field :condition-message "<con")
        (log-condition enabled +level-error+
                       (make-condition 'api-broken-condition) :message-limit 0)
        (expect (latest-fields handler) :to-have-field :condition-message ""))))

  (it "does not run reports by default and bounds opt-in reports"
    (let ((*condition-report-count* 0))
      (multiple-value-bind (logger handler) (counting-logger)
        (let ((condition (make-condition 'large-counting-report)))
          (log-condition logger +level-error+ condition :message-limit 64)
          (expect (= *condition-report-count* 0) :to-be-truthy)
          (let* ((record (latest-record handler))
                 (message (log-record-message record))
                 (condition-message (cdr (assoc :condition-message (log-record-fields record)))))
            (expect (string= message "<condition large-counting-report>") :to-be-truthy)
            (expect (string= message condition-message) :to-be-truthy))
          (log-condition logger +level-error+ condition :render-report t :message-limit 32)
          (expect (= *condition-report-count* 1) :to-be-truthy)
          (let* ((record (latest-record handler))
                 (message (log-record-message record))
                 (condition-message (cdr (assoc :condition-message (log-record-fields record)))))
            (expect (= (length message) 32) :to-be-truthy)
            (expect (string= message condition-message) :to-be-truthy)
            (expect (every (lambda (character) (char= character #\x)) message) :to-be-truthy))))))

  (it "merges explicit condition fields without allowing reserved spoofing"
    (let ((handler (make-instance 'counting-handler))
          (condition-evaluations 0)
          (field-evaluations 0))
      (let ((filtered (make-logger :level +level-error+ :fields '(:scope "logger")
                                   :handler handler))
            (enabled (make-logger :level +level-debug+ :fields '(:scope "logger")
                                  :handler handler)))
        (log-condition filtered +level-info+
                       (progn (incf condition-evaluations)
                              (make-condition 'api-broken-condition))
                       :fields (progn (incf field-evaluations) '(:scope "hidden")))
        (expect condition-evaluations :to-equal 0)
        (expect field-evaluations :to-equal 0)
        (with-log-context (:scope "context")
          (log-condition enabled +level-error+
                         (progn (incf condition-evaluations)
                                (make-condition 'api-broken-condition))
                         :fields (progn (incf field-evaluations)
                                        '(:scope "event" :extra t
                                          :condition-type "spoofed"
                                          :condition-message "spoofed"
                                          :backtrace "spoofed"))
                         :backtrace "actual"))
        (expect condition-evaluations :to-equal 1)
        (expect field-evaluations :to-equal 1)
        (let ((fields (latest-fields handler)))
          (expect fields :to-have-field :scope "event")
          (expect fields :to-have-field :extra t)
          (expect fields :to-have-field :condition-type "api-broken-condition")
          (expect fields :to-have-field :condition-message "<condition api-broken-condition>")
          (expect fields :to-have-field :backtrace "actual")))))

  (it "bounded output streams default a caller-omitted write-string end to the string length"
    (expect (log-kit::with-bounded-output (stream 100)
              (write-string "hello" stream))
            :to-equal "hello")))
