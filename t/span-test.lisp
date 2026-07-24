;;;; t/span-test.lisp
;;;
;;; WITH-LOG-SPAN: lazy metadata under filtering, paired :start / :end records
;;; with a parent/child span tree, and exit classification (:success, :error,
;;; :nonlocal-exit).
(in-package #:cl-log-kit/test)

(describe "log spans"
  (it "does not evaluate span metadata when the level is filtered"
    (multiple-value-bind (logger handler) (counting-logger :level +level-error+)
      (let ((name-evaluations 0) (field-evaluations 0) (clock-evaluations 0)
            (id-evaluations 0) (body-evaluations 0))
        (with-log-span (logger
                        (progn (incf name-evaluations) "hidden")
                        :level +level-info+
                        :fields (progn (incf field-evaluations) '(:hidden t))
                        :clock (progn (incf clock-evaluations) (lambda () 0))
                        :id-source (progn (incf id-evaluations) (lambda () "hidden")))
          (incf body-evaluations))
        (expect name-evaluations :to-equal 0)
        (expect field-evaluations :to-equal 0)
        (expect clock-evaluations :to-equal 0)
        (expect id-evaluations :to-equal 0)
        (expect body-evaluations :to-equal 1)
        (expect handler :to-have-recorded 0))))

  (it "emits nested span lifecycle records and preserves multiple values"
    (multiple-value-bind (logger handler)
        (counting-logger :level +level-debug+ :fields '(:scope "logger"))
      (let* ((times '(10 11 13 14))
             (ids '("outer" "inner"))
             (clock (lambda () (pop times)))
             (id-source (lambda () (pop ids)))
             (values (multiple-value-list
                       (with-log-span (logger "outer"
                                       :fields '(:scope "event" :span-id "spoofed")
                                       :clock clock :id-source id-source)
                         (with-log-span (logger "inner" :clock clock :id-source id-source)
                           (values 1 2))))))
        (expect values :to-equal '(1 2))
        (let* ((records (counting-handler-in-order handler))
               (outer-start (first records))
               (inner-start (second records))
               (inner-end (third records))
               (outer-end (fourth records))
               (outer-start-fields (log-record-fields outer-start))
               (inner-start-fields (log-record-fields inner-start))
               (inner-end-fields (log-record-fields inner-end))
               (outer-end-fields (log-record-fields outer-end)))
          (expect (length records) :to-equal 4)
          (expect outer-start-fields :to-have-field :span-event :start)
          (expect outer-start-fields :to-have-field :span-id "outer")
          (expect outer-start-fields :to-have-field :scope "event")
          (expect outer-start-fields :to-lack-field :parent-span-id)
          (expect inner-start-fields :to-have-field :span-event :start)
          (expect inner-start-fields :to-have-field :span-id "inner")
          (expect inner-start-fields :to-have-field :parent-span-id "outer")
          (expect inner-end-fields :to-have-field :span-event :end)
          (expect inner-end-fields :to-have-field :span-outcome :success)
          (expect inner-end-fields :to-have-field :span-duration 2)
          (expect outer-end-fields :to-have-field :span-event :end)
          (expect outer-end-fields :to-have-field :span-outcome :success)
          (expect outer-end-fields :to-have-field :span-duration 4)))))

  (it "classifies error and nonlocal span exits"
    (labels ((run-span (exit-kind)
               (multiple-value-bind (logger handler) (counting-logger)
                 (let* ((times '(20 24))
                        (clock (lambda () (pop times))))
                   (case exit-kind
                     (:error
                       (handler-case
                           (with-log-span (logger "error" :clock clock
                                           :id-source (lambda () "error"))
                             (error "failure"))
                         (error () nil)))
                     (:nonlocal-exit
                       (block leave
                         (with-log-span (logger "exit" :clock clock
                                         :id-source (lambda () "exit"))
                           (return-from leave :left)))))
                   (log-record-fields (latest-record handler))))))
      (let ((error-fields (run-span :error))
            (exit-fields (run-span :nonlocal-exit)))
        (expect error-fields :to-have-field :span-outcome :error)
        (expect error-fields :to-have-field :span-duration 4)
        (expect exit-fields :to-have-field :span-outcome :nonlocal-exit)
        (expect exit-fields :to-have-field :span-duration 4)))))

(progn
  (defclass end-failing-handler (counting-handler) ())

  (defmethod handle-log-record ((handler end-failing-handler) record)
    (call-next-method)
    (when (eq (cdr (assoc :span-event (log-record-fields record))) :end)
      (error "end handler failed"))
    handler))
(describe "span cleanup failures"
  (it "preserves the body error when the ending clock fails"
    (multiple-value-bind (logger handler) (counting-logger)
      (declare (ignore handler))
      (let ((calls 0)
            (primary (make-condition 'simple-error
                                     :format-control "body failed")))
        (let ((caught
                (handler-case
                    (with-log-span
                        (logger "clock failure"
                         :clock (lambda ()
                                  (if (zerop (prog1 calls (incf calls)))
                                      0
                                      "invalid ending time"))
                         :id-source (lambda () "clock-failure"))
                      (error primary))
                  (error (condition) condition))))
          (expect caught :to-be primary)))))

  (it "preserves the body error when the end handler fails"
    (let* ((handler (make-instance 'end-failing-handler))
           (logger (make-logger :handler handler))
           (times '(0 1))
           (primary (make-condition 'simple-error
                                    :format-control "body failed")))
      (let ((caught
              (handler-case
                  (with-log-span
                      (logger "handler failure"
                       :clock (lambda () (pop times))
                       :id-source (lambda () "handler-failure"))
                    (error primary))
                (error (condition) condition))))
        (expect caught :to-be primary))))

  (it "signals the end-record failure when the body already succeeded"
    (let* ((handler (make-instance 'end-failing-handler))
           (logger (make-logger :handler handler))
           (times '(0 1)))
      (signals error
        (with-log-span (logger "clean body"
                        :clock (lambda () (pop times))
                        :id-source (lambda () "clean-body"))
          t)))))
