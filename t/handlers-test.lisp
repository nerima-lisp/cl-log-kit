;;;; t/handlers-test.lisp
;;;
;;; The composite and terminal handlers built on the lifecycle.lisp backbone:
;;; MULTI-HANDLER (fan-out with an error policy), FILTER-HANDLER (predicate
;;; gate), FUNCTION-HANDLER (adapt a closure), and NULL-HANDLER. Mirrors
;;; src/handlers.lisp.
(in-package #:cl-log-kit/test)

;;; A function-handler that only records which records it was handed.
(defun recording-function-handler (sink)
  (make-function-handler (lambda (record) (funcall sink record))))

(describe "composite and terminal handler dispatch"
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
