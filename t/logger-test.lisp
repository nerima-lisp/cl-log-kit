;;;; t/logger-test.lisp

(in-package #:cl-log-kit/test)

(defun %capturing-logger (&key (level +level-info+) fields (clock #'get-universal-time))
  "Returns (values logger stream-fetcher), where STREAM-FETCHER is a
zero-argument function that returns everything written so far."
  (let* ((stream (make-string-output-stream))
         (logger (make-logger :handler (make-instance 'text-handler :stream stream)
                              :level level
                              :fields fields
                              :clock clock)))
    (values logger (lambda () (get-output-stream-string stream)))))

(it "logs at or above the logger's level"
  (multiple-value-bind (logger fetch) (%capturing-logger :level +level-warn+)
    (log-warn logger "disk low")
    (expect (not (null (search "disk low" (funcall fetch)))) :to-be-truthy)))

(it "filters out records below the logger's level without calling the handler"
  (multiple-value-bind (logger fetch) (%capturing-logger :level +level-warn+)
    (log-info logger "should not appear")
    (log-debug logger "should not appear either")
    (expect (string= (funcall fetch) "") :to-be-truthy)))

(it "each level threshold only lets its own level and above through"
  (multiple-value-bind (logger fetch) (%capturing-logger :level +level-error+)
    (log-warn logger "still filtered")
    (log-error logger "gets through")
    (let ((output (funcall fetch)))
      (expect (null (search "still filtered" output)) :to-be-truthy)
      (expect (not (null (search "gets through" output))) :to-be-truthy))))

(it "logger-with returns a new logger and does not mutate the parent's fields"
  (let* ((parent (make-logger :fields '(:service "api")))
         (child (logger-with parent :request-id "abc123")))
    (expect (not (eq parent child)) :to-be-truthy)
    (expect (equal (logger-fields parent) '((:service . "api"))) :to-be-truthy)
    (expect (equal (cdr (assoc :request-id (logger-fields child))) "abc123") :to-be-truthy)
    (expect (equal (cdr (assoc :service (logger-fields child))) "api") :to-be-truthy)))

(it "logger-with can be chained without affecting earlier loggers in the chain"
  (let* ((base (make-logger))
         (with-a (logger-with base :a 1))
         (with-b (logger-with with-a :b 2)))
    (expect (null (assoc :a (logger-fields base))) :to-be-truthy)
    (expect (null (assoc :b (logger-fields with-a))) :to-be-truthy)
    (expect (equal (cdr (assoc :a (logger-fields with-b))) 1) :to-be-truthy)
    (expect (equal (cdr (assoc :b (logger-fields with-b))) 2) :to-be-truthy)))

;;; A fixed clock makes timestamps deterministic and testable instead of
;;; depending on wall-clock time.
(it "an injected clock function determines the log-record timestamp"
  (let* ((stream (make-string-output-stream))
         (logger (make-logger :handler (make-instance 'json-handler :stream stream)
                              :clock (lambda () 999999))))
    (log-info logger "boot")
    (expect (not (null (search "\"timestamp\":999999" (get-output-stream-string stream))))
            :to-be-truthy)))

(it "the default clock produces a real, current-looking universal time"
  (let ((logger (make-logger)))
    (expect (> (funcall (logger-clock logger)) 3000000000) :to-be-truthy)))

(it "*default-logger* backs the logger-omitting convenience functions"
  (let* ((stream (make-string-output-stream))
         (logger (make-logger :handler (make-instance 'text-handler :stream stream)))
         (previous *default-logger*))
    (unwind-protect
         (progn
           (set-default-logger logger)
           (log-info "server started" :port 8080)
           (expect (not (null (search "server started port=8080" (get-output-stream-string stream))))
                   :to-be-truthy))
      (set-default-logger previous))))

(it "log-info accepts an explicit logger as its first argument"
  (let* ((stream (make-string-output-stream))
         (logger (make-logger :handler (make-instance 'text-handler :stream stream))))
    (log-info logger "explicit logger" :key "value")
    (expect (not (null (search "explicit logger key=value" (get-output-stream-string stream))))
            :to-be-truthy)))

(it "log-debug/log-warn/log-error/log-fatal all route through the same dispatcher"
  (let* ((stream (make-string-output-stream))
         (logger (make-logger :handler (make-instance 'text-handler :stream stream)
                              :level +level-debug+)))
    (log-debug logger "d")
    (log-warn logger "w")
    (log-error logger "e")
    (log-fatal logger "f")
    (let ((output (get-output-stream-string stream)))
      (expect (not (null (search "[DEBUG] d" output))) :to-be-truthy)
      (expect (not (null (search "[WARN] w" output))) :to-be-truthy)
      (expect (not (null (search "[ERROR] e" output))) :to-be-truthy)
      (expect (not (null (search "[FATAL] f" output))) :to-be-truthy))))

(it "make-logger's default level is info, so debug is filtered by default"
  (let* ((stream (make-string-output-stream))
         (logger (make-logger :handler (make-instance 'text-handler :stream stream))))
    (log-debug logger "hidden")
    (log-info logger "shown")
    (let ((output (get-output-stream-string stream)))
      (expect (null (search "hidden" output)) :to-be-truthy)
      (expect (not (null (search "shown" output))) :to-be-truthy))))
