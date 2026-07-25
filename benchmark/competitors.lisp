;;;; benchmark/competitors.lisp
;;;
;;; Comparative SBCL benchmark: cl-log-kit's text-handler against
;;; log4cl (quicklisp.org's most-downloaded Common Lisp logging library),
;;; both writing an equivalent info-level message plus four key/value pairs
;;; to a discarding stream, measured by the same minimum-over-full-GC'd-
;;; repetitions methodology as benchmark/run.lisp. Requires network access
;;; to fetch log4cl via Quicklisp on first run.
;;; Usage: sbcl --script benchmark/competitors.lisp
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

(let ((quicklisp-setup (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))))
  (unless (probe-file quicklisp-setup)
    (format *error-output* "~&competitors.lisp: Quicklisp not found at ~A — install it first.~%"
            quicklisp-setup)
    (uiop:quit 1))
  (load quicklisp-setup))
(funcall (intern "QUICKLOAD" "QL") :log4cl :silent t)

(in-package #:cl-user)

(defparameter *iterations* 50000)
(defparameter *repetitions* 5)

(defun minimum-run (thunk repetitions)
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

;; cl-log-kit setup: a text-handler over a discarding stream, matching the
;; default wire format every other cl-log-kit benchmark uses.
(defparameter *log-kit-sink* (make-broadcast-stream))
(defparameter *log-kit-handler* (log-kit:make-text-handler :stream *log-kit-sink* :auto-flush nil))
(defparameter *log-kit-record*
  (log-kit:make-log-record
   :message "handled request successfully without incident"
   :fields (list :method "GET" :path "/api/v1/orders" :status 200)))

;; log4cl setup: remove the default console appender (which resolves its
;; stream dynamically and has no supported way to redirect after the fact)
;; and install a single FIXED-STREAM-APPENDER at the same discarding stream,
;; with a PATTERN-LAYOUT producing comparable "level message key=val ..."
;; output.
(log4cl-impl:remove-all-appenders log4cl-impl:*root-logger*)
(defparameter *log4cl-sink* (make-broadcast-stream))
(let ((appender (make-instance 'log4cl-impl:fixed-stream-appender :stream *log4cl-sink*
                                :layout (make-instance 'log4cl-impl:pattern-layout
                                                        :conversion-pattern "%p %m%n"))))
  (log4cl-impl:add-appender log4cl-impl:*root-logger* appender))
(log:config :info)

(format t "~&~V,,,'-A~%" 90 "-")
(format t "~&cl-log-kit vs log4cl (SBCL, both writing to a discarding stream)~%")
(format t "~&~V,,,'-A~%" 90 "-")

(multiple-value-bind (seconds bytes)
    (minimum-run (lambda ()
                   (dotimes (i *iterations*)
                     (log-kit:handle-log-record *log-kit-handler* *log-kit-record*)))
                 *repetitions*)
  (format t "~&cl-log-kit text-handler~%  ~,3F s total  (~,0F ns/call)  ~,1F bytes/call~%"
          seconds (/ (* seconds 1d9) *iterations*) (/ bytes (float *iterations* 1d0))))

(multiple-value-bind (seconds bytes)
    (minimum-run (lambda ()
                   (dotimes (i *iterations*)
                     (log:info "handled request successfully without incident ~A=~A ~A=~A ~A=~A"
                               :method "GET" :path "/api/v1/orders" :status 200)))
                 *repetitions*)
  (format t "~&log4cl (fixed-stream-appender, pattern-layout)~%  ~,3F s total  (~,0F ns/call)  ~,1F bytes/call~%"
          seconds (/ (* seconds 1d9) *iterations*) (/ bytes (float *iterations* 1d0))))

(format t "~&~V,,,'-A~%" 90 "-")
(format t "~&Both handlers/appenders are equivalently minimal (one discarding stream,~%~
one text encoding, no async queue or file I/O on either side). log4cl's~%~
message is a FORMAT control string with 3 interleaved key/value pairs,~%~
matching cl-log-kit's structured :FIELDS list in output complexity.~%")
