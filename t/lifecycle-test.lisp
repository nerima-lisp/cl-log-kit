;;;; t/lifecycle-test.lisp
;;;
;;; The thread-safe close-once lifecycle shared by every composite handler:
;;; admitted operations, idempotent and retryable close, and the error-policy
;;; interaction with a failing child. Mirrors src/lifecycle.lisp.
(in-package #:cl-log-kit/test)

;;; A handler that exposes its own open/closed state, to prove HANDLER-OPEN-P
;;; is a specializable protocol.
(defclass introspectable-handler (handler)
  ((open-p :initform t :accessor introspectable-handler-open-p)))

(defmethod handle-log-record ((handler introspectable-handler) record)
  (declare (ignore record))
  handler)

(defmethod close-handler ((handler introspectable-handler))
  (setf (introspectable-handler-open-p handler) nil)
  handler)

(defmethod handler-open-p ((handler introspectable-handler))
  (introspectable-handler-open-p handler))

(describe "close-once lifecycle"
  (it "closes composition handlers exactly once across recursion and threads"
    (let ((close-count 0)
          (function-handler nil)
          (entered (sb-thread:make-semaphore))
          (release (sb-thread:make-semaphore))
          (second-returned (sb-thread:make-semaphore)))
      (setf function-handler
            (make-function-handler
              (lambda (record) (declare (ignore record)))
              :close-function (lambda ()
                                (incf close-count)
                                (sb-thread:signal-semaphore entered)
                                (close-handler function-handler)
                                (sb-thread:wait-on-semaphore release))))
      (let* ((filter (make-filter-handler
                       function-handler
                       (lambda (record) (declare (ignore record)) t)))
             (multi (make-multi-handler (list filter)))
             (first-thread (sb-thread:make-thread (lambda () (close-handler multi))))
             (second-thread nil))
        (expect (sb-thread:wait-on-semaphore entered :timeout 1) :to-be-truthy)
        (expect (not (handler-open-p function-handler)) :to-be-truthy)
        (expect (not (handler-open-p filter)) :to-be-truthy)
        (expect (not (handler-open-p multi)) :to-be-truthy)
        (setf second-thread (sb-thread:make-thread
                              (lambda () (close-handler multi)
                                (sb-thread:signal-semaphore second-returned)
                                t)))
        (expect (not (sb-thread:wait-on-semaphore second-returned :timeout 0.05)) :to-be-truthy)
        (sb-thread:signal-semaphore release)
        (expect (sb-thread:join-thread first-thread :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:join-thread second-thread :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:wait-on-semaphore second-returned :timeout 1) :to-be-truthy)
        (close-handler multi)
        (close-handler filter)
        (close-handler function-handler)
        (expect (= close-count 1) :to-be-truthy))))

  (it "closes a multi-handler whose child has no close protocol"
    ;; A null-handler (like any base-handler subclass) is always open by
    ;; design and its close is a no-op; closing a multi-handler that
    ;; contains one must succeed, not misread "still reports open" as
    ;; "close failed" and signal HANDLER-LIFECYCLE-ERROR.
    (let ((multi (make-multi-handler (list (make-null-handler)))))
      (close-handler multi)
      (expect (not (handler-open-p multi)) :to-be-truthy)
      (close-handler multi)
      (expect (not (handler-open-p multi)) :to-be-truthy)))

  (it "retries failed composition closes after attempting every child"
    (let ((failed-attempts 0) (later-close-count 0))
      (let* ((failing (make-function-handler
                        (lambda (record) (declare (ignore record)))
                        :close-function (lambda ()
                                          (incf failed-attempts)
                                          (when (= failed-attempts 1)
                                            (error "expected close failure")))))
             (later (make-function-handler
                      (lambda (record) (declare (ignore record)))
                      :close-function (lambda () (incf later-close-count))))
             (multi (make-multi-handler (list failing later))))
        (signals error (close-handler multi))
        (expect (= failed-attempts 1) :to-be-truthy)
        (expect (= later-close-count 1) :to-be-truthy)
        (expect (handler-open-p multi) :to-be-truthy)
        (expect (handler-open-p failing) :to-be-truthy)
        (expect (not (handler-open-p later)) :to-be-truthy)
        (close-handler multi)
        (close-handler multi)
        (expect (= failed-attempts 2) :to-be-truthy)
        (expect (= later-close-count 1) :to-be-truthy)
        (expect (not (handler-open-p multi)) :to-be-truthy)
        (expect (not (handler-open-p failing)) :to-be-truthy))))

  (it-each ((:continue nil)
            (:callback t))
      "retries multi-handler close failures under ~A policy~:[~; with an error callback~]"
      (error-policy expect-callback-p)
    (let ((failed-attempts 0) (later-close-count 0) (callback-count 0))
      (let* ((failing (make-function-handler
                        (lambda (record) (declare (ignore record)))
                        :close-function (lambda ()
                                          (incf failed-attempts)
                                          (when (= failed-attempts 1)
                                            (error "expected close failure")))))
             (later (make-function-handler
                      (lambda (record) (declare (ignore record)))
                      :close-function (lambda () (incf later-close-count))))
             (multi (if expect-callback-p
                        (make-multi-handler
                          (list failing later)
                          :error-policy error-policy
                          :error-callback (lambda (operation target condition)
                                            (declare (ignore operation target condition))
                                            (incf callback-count)))
                        (make-multi-handler (list failing later) :error-policy error-policy))))
        (signals error (close-handler multi))
        (when expect-callback-p (expect (= callback-count 1) :to-be-truthy))
        (expect (= later-close-count 1) :to-be-truthy)
        (expect (handler-open-p multi) :to-be-truthy)
        (expect (handler-open-p failing) :to-be-truthy)
        (close-handler multi)
        (expect (= failed-attempts 2) :to-be-truthy)
        (when expect-callback-p (expect (= callback-count 1) :to-be-truthy))
        (expect (= later-close-count 1) :to-be-truthy)
        (expect (not (handler-open-p multi)) :to-be-truthy))))

  (it "remembers an error-callback's own failure as the close error"
    (let ((failed-attempts 0) (callback-count 0))
      (let* ((failing (make-function-handler
                        (lambda (record) (declare (ignore record)))
                        :close-function (lambda ()
                                          (incf failed-attempts)
                                          (error "expected close failure"))))
             (multi (make-multi-handler
                      (list failing)
                      :error-policy :callback
                      :error-callback (lambda (operation target condition)
                                        (declare (ignore operation target condition))
                                        (incf callback-count)
                                        (error "callback itself failed")))))
        (signals error (close-handler multi))
        (expect (= callback-count 1) :to-be-truthy)
        (expect (handler-open-p multi) :to-be-truthy))))

  (it "rejects handle and flush after composition close without callbacks"
    (let ((function-handles 0) (function-flushes 0) (filter-predicates 0)
          (filter-handles 0) (filter-flushes 0) (multi-handles 0) (multi-flushes 0))
      (let* ((function (make-function-handler
                         (lambda (record) (declare (ignore record)) (incf function-handles))
                         :flush-function (lambda () (incf function-flushes))))
             (filter-target (make-function-handler
                              (lambda (record) (declare (ignore record)) (incf filter-handles))
                              :flush-function (lambda () (incf filter-flushes))))
             (filter (make-filter-handler
                       filter-target
                       (lambda (record) (declare (ignore record)) (incf filter-predicates) t)))
             (multi-target (make-function-handler
                             (lambda (record) (declare (ignore record)) (incf multi-handles))
                             :flush-function (lambda () (incf multi-flushes))))
             (multi (make-multi-handler (list multi-target)))
             (record (make-log-record :message "closed")))
        (dolist (handler (list function filter multi))
          (close-handler handler)
          (signals handler-lifecycle-error (handle-log-record handler record))
          (signals handler-lifecycle-error (flush-handler handler)))
        (dolist (counter (list function-handles function-flushes filter-predicates
                               filter-handles filter-flushes multi-handles multi-flushes))
          (expect (= counter 0) :to-be-truthy)))))

  (it "waits for an admitted handle before closing and rejects later work"
    (let ((entered (sb-thread:make-semaphore))
          (release (sb-thread:make-semaphore))
          (close-ran (sb-thread:make-semaphore))
          (handle-count 0))
      (let* ((handler (make-function-handler
                        (lambda (record) (declare (ignore record))
                          (incf handle-count)
                          (sb-thread:signal-semaphore entered)
                          (sb-thread:wait-on-semaphore release))
                        :close-function (lambda () (sb-thread:signal-semaphore close-ran))))
             (record (make-log-record :message "race"))
             (handle-thread (sb-thread:make-thread
                              (lambda () (handle-log-record handler record))))
             (close-thread nil))
        (expect (sb-thread:wait-on-semaphore entered :timeout 1) :to-be-truthy)
        (setf close-thread (sb-thread:make-thread (lambda () (close-handler handler))))
        (loop repeat 1000 while (handler-open-p handler) do (sleep 0.001))
        (expect (not (handler-open-p handler)) :to-be-truthy)
        (signals handler-lifecycle-error (handle-log-record handler record))
        (expect (= handle-count 1) :to-be-truthy)
        (expect (not (sb-thread:wait-on-semaphore close-ran :timeout 0.05)) :to-be-truthy)
        (sb-thread:signal-semaphore release)
        (expect (sb-thread:join-thread handle-thread :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:join-thread close-thread :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:wait-on-semaphore close-ran :timeout 1) :to-be-truthy))))

  (it "allows custom handlers to specialize lifecycle introspection"
    (let ((handler (make-instance 'introspectable-handler)))
      (expect (handler-open-p handler) :to-be-truthy)
      (close-handler handler)
      (expect (not (handler-open-p handler)) :to-be-truthy)))

  (it "provides stream constructors and unwind-safe lifecycle"
    (let ((stream (make-string-output-stream))
          (handler nil))
      (handler-case
          (with-handler (owned (make-text-handler :stream stream :owns-stream nil))
            (setf handler owned)
            (expect (handler-open-p owned) :to-be-truthy)
            (error "leave"))
        (error () nil))
      (expect (not (handler-open-p handler)) :to-be-truthy))
    (let* ((handler (make-null-handler))
           (logger (make-logger :handler handler)))
      (expect (eq (flush-logger logger) logger) :to-be-truthy))))
