;;;; t/thread-context-test.lisp
;;;
;;; CAPTURE-LOG-CONTEXT / CALL-WITH-CAPTURED-LOG-CONTEXT / WITH-CAPTURED-LOG-CONTEXT:
;;; snapshotting the active WITH-LOG-CONTEXT fields and WITH-LOG-SPAN span id
;;; and replaying them later, including across a real SB-THREAD boundary
;;; where the dynamic bindings are not otherwise inherited.
(in-package #:cl-log-kit/test)

(describe "log context propagation"
  (it "captures an empty context when no dynamic context or span is active"
    (let ((snapshot (capture-log-context)))
      (expect (log-context-snapshot-p snapshot) :to-be-truthy)
      (multiple-value-bind (logger handler) (counting-logger)
        (with-captured-log-context (snapshot)
          (log-info logger "isolated"))
        (expect (latest-fields handler) :to-lack-field :request-id))))

  (it "restores context fields captured earlier, after the original dynamic extent has exited"
    (multiple-value-bind (logger handler) (counting-logger)
      (let (snapshot)
        (with-log-context (:request-id "abc123")
          (setf snapshot (capture-log-context)))
        ;; *LOG-CONTEXT-FIELDS* is back to its outer (empty) value here;
        ;; restoring SNAPSHOT must not depend on still being inside the
        ;; WITH-LOG-CONTEXT that captured it.
        (with-captured-log-context (snapshot)
          (log-info logger "later"))
        (expect (latest-fields handler) :to-have-field :request-id "abc123"))))

  (it "replaces rather than merges with any context active where it is restored"
    (multiple-value-bind (logger handler) (counting-logger)
      (let ((snapshot (capture-log-context)))
        (with-log-context (:ambient t)
          (with-captured-log-context (snapshot)
            (log-info logger "isolated"))
          (expect (latest-fields handler) :to-lack-field :ambient)))))

  (it "rejects a non-snapshot argument"
    (signals type-error (call-with-captured-log-context :not-a-snapshot (lambda () nil))))

  (it "propagates captured context fields into a real worker thread"
    (multiple-value-bind (logger handler) (counting-logger :level +level-debug+)
      (let (snapshot thread)
        (with-log-context (:request-id "abc123")
          (setf snapshot (capture-log-context)))
        (setf thread
              (sb-thread:make-thread
                (lambda ()
                  (with-captured-log-context (snapshot)
                    (log-info logger "from worker")))))
        (unless (sb-thread:join-thread thread :timeout 1 :default nil)
          (sb-thread:terminate-thread thread))
        (expect (latest-fields handler) :to-have-field :request-id "abc123"))))

  (it "restores the parent span id inside a worker thread's own nested span"
    (multiple-value-bind (logger handler) (counting-logger :level +level-debug+)
      (let (snapshot thread)
        (with-log-span (logger "outer" :id-source (lambda () "outer-id"))
          (setf snapshot (capture-log-context)))
        (setf thread
              (sb-thread:make-thread
                (lambda ()
                  (with-captured-log-context (snapshot)
                    (with-log-span (logger "inner" :id-source (lambda () "inner-id"))
                      nil))
                  t)))
        (unless (sb-thread:join-thread thread :timeout 1 :default nil)
          (sb-thread:terminate-thread thread))
        (let ((inner-start (find-if (lambda (record)
                                      (let ((fields (log-record-fields record)))
                                        (and (equal (cdr (assoc :span-id fields)) "inner-id")
                                             (eq (cdr (assoc :span-event fields)) :start))))
                                    (counting-handler-in-order handler))))
          (expect inner-start :to-be-truthy)
          (expect (log-record-fields inner-start) :to-have-field :parent-span-id "outer-id"))))))
