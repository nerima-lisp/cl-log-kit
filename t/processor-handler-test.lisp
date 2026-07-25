;;;; t/processor-handler-test.lisp
;;;
;;; PROCESSOR-HANDLER: running a chain of enrichment functions over a record
;;; before forwarding it to a target handler. Mirrors
;;; src/processor-handler.lisp.
(in-package #:cl-log-kit/test)

(describe "processor handler"
  (it "enriches a record with a processor's contributed fields"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-processor-handler target
                                            :processors (list (lambda (record)
                                                                (declare (ignore record))
                                                                (list :host "web-1"))))))
      (handle-log-record handler (make-log-record :message "event"))
      (expect (latest-fields target) :to-have-field :host "web-1")))

  (it "runs processors in order, each observing the prior one's contribution"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-processor-handler
                     target
                     :processors (list (lambda (record) (declare (ignore record)) (list :a "1"))
                                       (lambda (record)
                                         (list :b (if (assoc :a (log-record-fields record))
                                                      "saw-a"
                                                      "missing")))))))
      (handle-log-record handler (make-log-record :message "event"))
      (expect (latest-fields target) :to-have-field :a "1")
      (expect (latest-fields target) :to-have-field :b "saw-a")))

  (it "lets a later processor override an earlier one at the same key"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-processor-handler
                     target
                     :processors (list (lambda (record) (declare (ignore record)) (list :x "from-1"))
                                       (lambda (record) (declare (ignore record)) (list :x "from-2"))))))
      (handle-log-record handler (make-log-record :message "event"))
      (expect (latest-fields target) :to-have-field :x "from-2")))

  (it "never lets a processor override a field already present on the record"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-processor-handler
                     target
                     :processors (list (lambda (record) (declare (ignore record)) (list :request-id "spoofed"))))))
      (handle-log-record handler (make-log-record :message "event" :fields '(:request-id "real")))
      (expect (latest-fields target) :to-have-field :request-id "real")))

  (it "forwards unmodified when a processor contributes nothing"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-processor-handler target :processors (list (lambda (record)
                                                                       (declare (ignore record)) nil)))))
      (handle-log-record handler (make-log-record :message "event" :fields '(:k "v")))
      (expect (latest-fields target) :to-have-field :k "v")))

  (it "rejects a non-function processor and a non-handler target"
    (signals type-error (make-processor-handler (make-null-handler) :processors (list :not-a-function)))
    (signals type-error (make-processor-handler :not-a-handler)))

  (it "rejects a non-proper-list processor collection"
    (signals invalid-log-fields (make-processor-handler (make-null-handler) :processors '(1 . 2))))

  (it "defaults optional slots for direct instance construction"
    (let ((handler (make-instance 'processor-handler :target (make-null-handler))))
      (expect (handler-open-p handler) :to-be-truthy)))

  (it "flushes and closes through to the target"
    (let ((flushes 0))
      (let* ((target (make-function-handler (lambda (record) (declare (ignore record)))
                                            :flush-function (lambda () (incf flushes))))
             (handler (make-processor-handler target)))
        (flush-handler handler)
        (expect (= flushes 1) :to-be-truthy)
        (close-handler handler)
        (expect (not (handler-open-p target)) :to-be-truthy)))))
