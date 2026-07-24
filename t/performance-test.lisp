;;;; t/performance-test.lisp
;;;
;;; Performance guarantees: the log macros do not evaluate their arguments when
;;; filtered, and (on SBCL) filtered logging conses nothing per call while
;;; enabled logging and backtrace capture stay within fixed allocation bounds.
(in-package #:cl-log-kit/test)

(describe "performance"
  (it "does not evaluate filtered explicit log arguments"
    (let ((logger (make-logger :level +level-fatal+))
          (evaluated nil))
      (log-info logger
                (progn (push :message evaluated) "filtered")
                :field (progn (push :field evaluated) 42))
      (expect (null evaluated) :to-be-truthy)))

  (it "does not evaluate filtered default log arguments"
    (let ((*default-logger* (make-logger :level +level-fatal+))
          (evaluated nil))
      (log-default-info (progn (push :message evaluated) "filtered")
                        :field (progn (push :field evaluated) 42))
      (expect (null evaluated) :to-be-truthy))))

;;; The allocation benchmarks below rely on SBCL's GET-BYTES-CONSED, so they
;;; are compiled only under SBCL.
#+sbcl
(progn
  (declaim (notinline %run-filtered-level-check-loop
                      %run-filtered-info-loop
                      %run-enabled-info-loop))

  (defun %run-filtered-level-check-loop (logger iterations)
    (dotimes (index iterations)
      (when (log-enabled-p logger +level-info+)
        (error "Benchmark logger unexpectedly enabled INFO"))))

  (defun %run-filtered-info-loop (logger iterations)
    (dotimes (index iterations)
      (log-info logger "filtered" :answer 42)))

  (defun %run-enabled-info-loop (logger iterations)
    (dotimes (index iterations)
      (log-info logger "enabled" :answer 42)))

  ;; Minimum bytes consed by THUNK over REPETITIONS runs, each after a full GC,
  ;; so transient GC noise does not mask the steady-state allocation.
  (defun %minimum-bytes-consed (thunk repetitions)
    (loop repeat repetitions
          minimize (progn
                     (sb-ext:gc :full t)
                     (let ((before (sb-ext:get-bytes-consed)))
                       (funcall thunk)
                       (- (sb-ext:get-bytes-consed) before)))))

  (defun %large-field-record ()
    (let ((payload (make-string log-kit::+max-log-field-string-length+
                                :initial-element #\x)))
      (make-log-record
        :message "large fields"
        :fields (loop for index below 16
                      append (list (intern (format nil "FIELD-~D" index) :keyword)
                                   payload)))))

  (describe "allocation bounds"
    (it "adds no per-call consing for filtered logging"
      (let ((logger (make-logger :level +level-fatal+))
            (iterations 10000))
        (%run-filtered-info-loop logger 100)
        (let ((baseline (%minimum-bytes-consed
                          (lambda () (%run-filtered-level-check-loop logger iterations)) 3))
              (logged (%minimum-bytes-consed
                        (lambda () (%run-filtered-info-loop logger iterations)) 3)))
          (expect (<= logged baseline) :to-be-truthy))))

    (it "keeps enabled text logging allocation bounded"
      (let* ((stream (make-broadcast-stream))
             (handler (make-text-handler :stream stream))
             (logger (make-logger :handler handler :level +level-info+))
             (iterations 100))
        (%run-enabled-info-loop logger 10)
        (let ((bytes (%minimum-bytes-consed
                       (lambda () (%run-enabled-info-loop logger iterations)) 3)))
          (expect (< bytes (* iterations 16384)) :to-be-truthy))))

    (it "bounds allocation while capturing truncated backtraces"
      (let* ((iterations 100)
             (capture (lambda ()
                        (dotimes (index iterations)
                          (log-kit::%capture-condition-backtrace 8)))))
        (funcall capture)
        (let ((bytes (%minimum-bytes-consed capture 3)))
          (expect (< bytes (* iterations 65536)) :to-be-truthy))))

    (it "streams large text records without aggregate allocation"
      (let* ((record (%large-field-record))
             (handler (make-text-handler :stream (make-broadcast-stream) :auto-flush nil))
             (bytes (%minimum-bytes-consed
                      (lambda () (handle-log-record handler record)) 3)))
        (expect (< bytes (* 4 1024 1024)) :to-be-truthy)))

    (it "streams large JSON records without aggregate allocation"
      (let* ((record (%large-field-record))
             (handler (make-json-handler :stream (make-broadcast-stream) :auto-flush nil))
             (bytes (%minimum-bytes-consed
                      (lambda () (handle-log-record handler record)) 3)))
        (expect (< bytes (* 4 1024 1024)) :to-be-truthy)))

    (it "snapshots only the bounded explicit backtrace prefix"
      (let* ((condition (make-condition 'simple-error :format-control "boom"
                                        :format-arguments nil))
             (backtrace (make-string (* 16 1024 1024) :initial-element #\b))
             (bytes (%minimum-bytes-consed
                      (lambda () (log-kit::%condition-fields condition "boom" backtrace nil 8))
                      3)))
        (expect (< bytes (* 1024 1024)) :to-be-truthy)))))
