;;;; benchmark/run.lisp
;;;
;;; Reproducible SBCL benchmark for cl-log-kit's own hot paths: minimum
;;; wall-clock time and bytes consed per call, taken over several full-GC'd
;;; repetitions so GC noise cannot mask the steady-state cost. Mirrors the
;;; benchmark/ convention already used by nerima-lisp/cl-json-kit.
;;; Usage: sbcl --script benchmark/run.lisp
(require :asdf)

(defun script-directory ()
  (make-pathname :name nil :type nil
                 :defaults (or *load-truename*
                              *compile-file-truename*
                              (error "Unable to determine the script location"))))

(defun configure-source-registry (root)
  (let* ((local-registry (format nil "~A//" (namestring root)))
         (existing (uiop:getenv "CL_SOURCE_REGISTRY"))
         (combined (if (and existing (plusp (length existing)))
                      (format nil "~A:~A" local-registry existing)
                      (format nil "~A:" local-registry))))
    (setf (uiop:getenv "CL_SOURCE_REGISTRY") combined)
    (asdf:initialize-source-registry)))

(let ((root (merge-pathnames "../" (script-directory))))
  (configure-source-registry root))

(handler-bind ((warning #'muffle-warning))
  (asdf:load-system "cl-log-kit"))

(in-package #:cl-user)

(defparameter *iterations* 50000)
(defparameter *repetitions* 5)

(defun minimum-run (thunk repetitions)
  "Return (values minimum-seconds minimum-bytes-consed) over REPETITIONS
full-GC'd runs of THUNK."
  (let ((best-time nil) (best-bytes nil))
    (dotimes (i repetitions)
      (sb-ext:gc :full t)
      (let* ((before-bytes (sb-ext:get-bytes-consed))
             (before-time (get-internal-real-time)))
        (funcall thunk)
        (let ((elapsed (/ (- (get-internal-real-time) before-time)
                          (float internal-time-units-per-second 1d0)))
              (consed (- (sb-ext:get-bytes-consed) before-bytes)))
          (when (or (null best-time) (< elapsed best-time)) (setf best-time elapsed))
          (when (or (null best-bytes) (< consed best-bytes)) (setf best-bytes consed)))))
    (values best-time best-bytes)))

(defmacro define-benchmark (name (&rest setup) &body body)
  `(list ,name (lambda () (let* ,setup (lambda () ,@body)))))

(defparameter *benchmarks*
  (list
   (define-benchmark "text-handler: plain ASCII message + 3 fields"
       ((stream (make-broadcast-stream))
        (handler (log-kit:make-text-handler :stream stream :auto-flush nil))
        (record (log-kit:make-log-record
                 :message "handled request successfully without incident"
                 :fields (list :method "GET" :path "/api/v1/orders" :status 200))))
     (dotimes (i *iterations*) (log-kit:handle-log-record handler record)))
   (define-benchmark "json-handler: plain ASCII message + 3 fields"
       ((stream (make-broadcast-stream))
        (handler (log-kit:make-json-handler :stream stream :auto-flush nil))
        (record (log-kit:make-log-record
                 :message "handled request successfully without incident"
                 :fields (list :method "GET" :path "/api/v1/orders" :status 200))))
     (dotimes (i *iterations*) (log-kit:handle-log-record handler record)))
   (define-benchmark "text-handler: long plain-ASCII field value (256 chars)"
       ((stream (make-broadcast-stream))
        (handler (log-kit:make-text-handler :stream stream :auto-flush nil))
        (payload (make-string 256 :initial-element #\a))
        (record (log-kit:make-log-record :message "payload" :fields (list :body payload))))
     (dotimes (i *iterations*) (log-kit:handle-log-record handler record)))
   (define-benchmark "json-handler: long plain-ASCII field value (256 chars)"
       ((stream (make-broadcast-stream))
        (handler (log-kit:make-json-handler :stream stream :auto-flush nil))
        (payload (make-string 256 :initial-element #\a))
        (record (log-kit:make-log-record :message "payload" :fields (list :body payload))))
     (dotimes (i *iterations*) (log-kit:handle-log-record handler record)))
   (define-benchmark "json-handler: double-float-heavy fields"
       ((stream (make-broadcast-stream))
        (handler (log-kit:make-json-handler :stream stream :auto-flush nil))
        (record (log-kit:make-log-record
                 :message "metrics"
                 :fields (list :latency-ms 123.456d0 :cpu-pct 0.8734d0
                               :memory-mb 2048.5d0 :queue-depth 17.0d0))))
     (dotimes (i *iterations*) (log-kit:handle-log-record handler record)))))

(format t "~&~V,,,'-A~%" 90 "-")
(format t "~&~A~%" "cl-log-kit benchmark (SBCL)")
(format t "~&~V,,,'-A~%" 90 "-")
(dolist (entry *benchmarks*)
  (destructuring-bind (name maker) entry
    (let ((thunk (funcall maker)))
      (multiple-value-bind (seconds bytes) (minimum-run thunk *repetitions*)
        (format t "~&~A~%  ~,3F s total  (~,0F ns/call)  ~,1F MB total  (~,1F bytes/call)~%"
                name seconds (/ (* seconds 1d9) *iterations*)
                (/ bytes (* 1024 1024.0)) (/ bytes (float *iterations* 1d0)))))))
(format t "~&~V,,,'-A~%" 90 "-")
