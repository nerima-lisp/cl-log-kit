;;;; t/composition-test.lisp
;;;
;;; Composite and terminal handlers (multi / filter / function / null), the
;;; thread-safe close-once lifecycle they share, and LOG-CONDITION's lazy,
;;; bounded rendering of conditions into fields.
(in-package #:cl-log-kit/test)

;;; A condition whose report itself errors, to prove reports run only on
;;; demand and failures degrade gracefully.
(define-condition api-broken-condition (error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition stream))
             (error "broken report"))))

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

;;; A condition whose report is huge and counts its invocations, to bound
;;; opt-in report rendering.
(defvar *condition-report-count* 0)

(define-condition large-counting-report (error) ()
  (:report (lambda (condition stream)
             (declare (ignore condition))
             (incf *condition-report-count*)
             (loop repeat 1000000 do (write-char #\x stream)))))

;;; A function-handler that only records which records it was handed.
(defun recording-function-handler (sink)
  (make-function-handler (lambda (record) (funcall sink record))))

(describe "handler composition"
  (describe "dispatch"
    (it "dispatches composite handlers in order with partial-failure policy"
      (let ((calls nil) (callback-operation nil))
        (let* ((first (make-function-handler
                        (lambda (record) (declare (ignore record))
                          (setf calls (append calls '(:first))))))
               (failing (make-function-handler
                          (lambda (record) (declare (ignore record)) (error "failed"))))
               (last (make-function-handler
                       (lambda (record) (declare (ignore record))
                         (setf calls (append calls '(:last))))))
               (multi (make-multi-handler
                        (list first failing last)
                        :error-policy :callback
                        :error-callback (lambda (operation target condition)
                                          (declare (ignore target condition))
                                          (setf callback-operation operation)))))
          (handle-log-record multi (make-log-record :message "event"))
          (expect (equal calls '(:first :last)) :to-be-truthy)
          (expect (eq callback-operation :handle) :to-be-truthy))))

    (it "records handle calls on a mock function-handler"
      (let* ((sink (make-mock-function (lambda (record) (declare (ignore record)) nil)))
             (handler (make-function-handler sink))
             (record (make-log-record :message "mocked")))
        (handle-log-record handler record)
        (handle-log-record handler record)
        (expect sink :to-have-been-called)
        (expect sink :to-have-been-called-times 2)
        (expect sink :to-have-been-called-with record)
        (clear-mock sink)
        (expect sink :not :to-have-been-called)))

    (it "does not swallow warnings from composite handlers"
      (let ((warning-seen-p nil)
            (handler (make-multi-handler
                       (list (make-function-handler
                               (lambda (record) (declare (ignore record))
                                 (warn "visible warning"))))
                       :error-policy :continue)))
        (handler-bind ((warning (lambda (condition)
                                  (declare (ignore condition))
                                  (setf warning-seen-p t)
                                  (muffle-warning))))
          (handle-log-record handler (make-log-record :message "event")))
        (expect warning-seen-p :to-be-truthy)))

    (it "filters and discards records through composition handlers"
      (let ((count 0))
        (let* ((target (recording-function-handler (lambda (record)
                                                     (declare (ignore record)) (incf count))))
               (filter (make-filter-handler
                         target
                         (lambda (record) (>= (log-record-level record) +level-warn+)))))
          (handle-log-record filter (make-log-record :level +level-info+))
          (handle-log-record filter (make-log-record :level +level-error+))
          (handle-log-record (make-null-handler) (make-log-record))
          (expect (= count 1) :to-be-truthy))))

    (it "defaults optional slots for direct handler construction"
      (let* ((failing-target (make-function-handler
                               (lambda (record) (declare (ignore record))
                                 (error "expected handle failure"))))
             (multi (make-instance 'multi-handler :handlers (list failing-target)))
             (function (make-instance 'function-handler
                                      :handle-function (lambda (record) (declare (ignore record))))))
        (signals error (handle-log-record multi (make-log-record)))
        (flush-handler function)
        (close-handler function)
        (expect (not (handler-open-p function)) :to-be-truthy)
        (close-handler multi)))

    (it "flushes every child of an open multi-handler and an open filter-handler's target"
      (let ((multi-flushes 0) (filter-flushes 0))
        (let* ((multi-target (make-function-handler
                               (lambda (record) (declare (ignore record)))
                               :flush-function (lambda () (incf multi-flushes))))
               (multi (make-multi-handler (list multi-target)))
               (filter-target (make-function-handler
                                (lambda (record) (declare (ignore record)))
                                :flush-function (lambda () (incf filter-flushes))))
               (filter (make-filter-handler
                        filter-target (lambda (record) (declare (ignore record)) t))))
          (flush-handler multi)
          (flush-handler filter)
          (expect (= multi-flushes 1) :to-be-truthy)
          (expect (= filter-flushes 1) :to-be-truthy)))))

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

    (progn
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
  (it "retries multi-handler close failures under continue policy"
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
             (multi (make-multi-handler (list failing later) :error-policy :continue)))
        (signals error (close-handler multi))
        (expect (= later-close-count 1) :to-be-truthy)
        (expect (handler-open-p multi) :to-be-truthy)
        (expect (handler-open-p failing) :to-be-truthy)
        (close-handler multi)
        (expect (= failed-attempts 2) :to-be-truthy)
        (expect (= later-close-count 1) :to-be-truthy)
        (expect (not (handler-open-p multi)) :to-be-truthy))))
  (it "retries multi-handler close failures under callback policy"
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
             (multi (make-multi-handler
                      (list failing later)
                      :error-policy :callback
                      :error-callback (lambda (operation target condition)
                                        (declare (ignore operation target condition))
                                        (incf callback-count)))))
        (signals error (close-handler multi))
        (expect (= callback-count 1) :to-be-truthy)
        (expect (= later-close-count 1) :to-be-truthy)
        (expect (handler-open-p multi) :to-be-truthy)
        (expect (handler-open-p failing) :to-be-truthy)
        (close-handler multi)
        (expect (= failed-attempts 2) :to-be-truthy)
        (expect (= callback-count 1) :to-be-truthy)
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
        (expect (handler-open-p multi) :to-be-truthy)))))

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
              :to-equal "hello"))))
