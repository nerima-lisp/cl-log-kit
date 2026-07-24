;;;; run-ci.lisp
;;;
;;; Timeout-enforced CI entry point. Runs run-tests.lisp or run-coverage.lisp
;;; as a child SBCL process via nerima-lisp/cl-process-kit's RUN, so a hang
;;; in either script (a reintroduced lifecycle deadlock, a runaway compile)
;;; fails the build after a bounded wait and an escalating SIGTERM/SIGKILL
;;; instead of hanging CI indefinitely. This is the enforced, in-repo
;;; replacement for the `timeout 120s sbcl --script ...` shell convention
;;; documented in earlier revisions of README.md: the timeout now lives in
;;; the repository itself instead of depending on every caller remembering
;;; to prepend it.
;;;
;;; cl-process-kit is dev tooling only: it is not a dependency of the
;;; cl-log-kit or cl-log-kit/test ASDF systems, so the shipped library stays
;;; dependency-free.
;;;
;;; Usage: sbcl --script run-ci.lisp tests|coverage [timeout-seconds]
(require :asdf)

(defun script-directory ()
  (make-pathname :name nil :type nil
                 :defaults (or *load-truename*
                              *compile-file-truename*
                              (error "Unable to determine the script location"))))

(defun configure-source-registry (root)
  "Prepend ROOT to CL_SOURCE_REGISTRY while preserving its existing configuration."
  (let* ((local-registry (format nil "~A//" (namestring root)))
         (existing (uiop:getenv "CL_SOURCE_REGISTRY"))
         (combined (if (and existing (plusp (length existing)))
                      (format nil "~A:~A" local-registry existing)
                      (format nil "~A:" local-registry))))
    (setf (uiop:getenv "CL_SOURCE_REGISTRY") combined)
    (asdf:initialize-source-registry)))

(defun target-script (target)
  (cond
    ((string= target "tests") "run-tests.lisp")
    ((string= target "coverage") "run-coverage.lisp")
    (t (error "run-ci.lisp: unknown target ~S (expected \"tests\" or \"coverage\")" target))))

(let ((root (script-directory)))
  (configure-source-registry root)
  (handler-bind ((warning #'muffle-warning))
    (asdf:load-system "cl-process-kit"))
  (destructuring-bind (&optional (target "tests") timeout-string)
      (uiop:command-line-arguments)
    (let* ((script (target-script target))
           (timeout-seconds (if timeout-string (parse-integer timeout-string) 120))
           (script-path (namestring (merge-pathnames script root))))
      (handler-case
          (let ((result (uiop:symbol-call :process-kit :run "sbcl" (list "--script" script-path)
                                          :timeout-seconds timeout-seconds
                                          :on-timeout :error)))
            (write-string (uiop:symbol-call :process-kit :process-result-stdout result))
            (write-string (uiop:symbol-call :process-kit :process-result-stderr result) *error-output*)
            (uiop:quit (or (uiop:symbol-call :process-kit :process-result-exit-code result) 1)))
        (error (condition)
          (format *error-output* "~&run-ci.lisp: ~A exceeded its ~Ds timeout and was terminated: ~A~%"
                  script timeout-seconds condition)
          (uiop:quit 124))))))
