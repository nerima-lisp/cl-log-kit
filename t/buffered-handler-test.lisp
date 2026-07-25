;;;; t/buffered-handler-test.lisp
;;;
;;; BUFFERED-HANDLER: holding records back until a trigger-level record
;;; arrives, then releasing the held-back run in order. Mirrors
;;; src/buffered-handler.lisp.
(in-package #:cl-log-kit/test)

(defun buffered-messages (handler)
  (mapcar #'log-record-message (counting-handler-in-order handler)))

(describe "buffered handler"
  (it "buffers records below the trigger level without forwarding them"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-buffered-handler target :trigger-level +level-error+)))
      (handle-log-record handler (make-log-record :level +level-info+ :message "m1"))
      (handle-log-record handler (make-log-record :level +level-info+ :message "m2"))
      (expect target :to-have-recorded 0)))

  (it "releases the whole buffer, including the trigger record, in order"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-buffered-handler target :trigger-level +level-error+)))
      (handle-log-record handler (make-log-record :level +level-info+ :message "m1"))
      (handle-log-record handler (make-log-record :level +level-info+ :message "m2"))
      (handle-log-record handler (make-log-record :level +level-error+ :message "boom"))
      (expect (buffered-messages target) :to-equal '("m1" "m2" "boom"))))

  (it "stays activated after the trigger by default, forwarding later records directly"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-buffered-handler target :trigger-level +level-error+)))
      (handle-log-record handler (make-log-record :level +level-error+ :message "boom"))
      (handle-log-record handler (make-log-record :level +level-info+ :message "after"))
      (expect (buffered-messages target) :to-equal '("boom" "after"))))

  (it "re-arms buffering after each flush when stop-buffering is false"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-buffered-handler target :trigger-level +level-error+ :stop-buffering nil)))
      (handle-log-record handler (make-log-record :level +level-error+ :message "boom"))
      (handle-log-record handler (make-log-record :level +level-info+ :message "quiet"))
      (expect (buffered-messages target) :to-equal '("boom"))
      (handle-log-record handler (make-log-record :level +level-error+ :message "boom-again"))
      (expect (buffered-messages target) :to-equal '("boom" "quiet" "boom-again"))))

  (it "drops the oldest buffered record once buffer-size is exceeded"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-buffered-handler target :trigger-level +level-error+ :buffer-size 2)))
      (handle-log-record handler (make-log-record :level +level-info+ :message "oldest"))
      (handle-log-record handler (make-log-record :level +level-info+ :message "m2"))
      (handle-log-record handler (make-log-record :level +level-info+ :message "m3"))
      (handle-log-record handler (make-log-record :level +level-error+ :message "boom"))
      (expect (buffered-messages target) :to-equal '("m2" "m3" "boom"))))

  (it "does not force an unflushed buffer out on flush-handler or close-handler"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-buffered-handler target :trigger-level +level-error+)))
      (handle-log-record handler (make-log-record :level +level-info+ :message "held"))
      (flush-handler handler)
      (expect target :to-have-recorded 0)
      (close-handler handler)
      (expect target :to-have-recorded 0)))

  (it "rejects a non-integer trigger level and a non-handler target"
    (signals type-error (make-buffered-handler (make-null-handler) :trigger-level :bogus))
    (signals type-error (make-buffered-handler :not-a-handler)))

  (it "defaults optional slots for direct instance construction"
    (let* ((target (make-instance 'counting-handler))
           (handler (make-instance 'buffered-handler :target target)))
      (handle-log-record handler (make-log-record :level +level-error+ :message "boom"))
      (expect (buffered-messages target) :to-equal '("boom")))))
