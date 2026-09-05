(require :asdf)
(require :sb-cover)

;; Keep direct runs bounded like the Nix test wrapper.
(defparameter *timeout-seconds* 120)

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

;; Keep the floor below the observed aggregate to avoid platform-specific
;; accounting noise while still catching real regressions.
(defparameter *coverage-minimum-expression* 94.9)
(defparameter *coverage-minimum-branch* 98.45)

(let* ((root (script-directory))
       (src-dir (merge-pathnames #P"src/" root))
       (coverage-dir (merge-pathnames #P"coverage/" root))
       (coverage-index (merge-pathnames #P"cover-index.html" coverage-dir)))
  (configure-source-registry root)

  ;; Instrument the library only: proclaim before its (forced) recompile, then
  ;; drop instrumentation so the test system stays uninstrumented.
  ;; No coverage reset: this keeps load-time coverage of the definition forms.
  (proclaim '(optimize sb-cover:store-coverage-data))
  (handler-bind ((warning #'muffle-warning))
    (asdf:load-system "cl-log-kit" :force t))
  (proclaim '(optimize (sb-cover:store-coverage-data 0)))

  (handler-bind ((warning #'muffle-warning))
    (asdf:load-system "cl-log-kit/test"))

  (handler-case
      (unless (sb-ext:with-timeout *timeout-seconds*
                (uiop:symbol-call :cl-weave :run-all
                                  :reporter :spec
                                  :coverage t
                                  ;; Match the manual sb-cover invocation this
                                  ;; replaces: RUN-ALL's own :coverage-reset
                                  ;; default of T would wipe the load-time
                                  ;; coverage credit from the instrumented
                                  ;; ASDF:LOAD-SYSTEM above before a single
                                  ;; test runs.
                                  :coverage-reset nil
                                  :coverage-report-directory coverage-dir
                                  :coverage-include-pathnames (list src-dir)
                                  :coverage-minimum-expression *coverage-minimum-expression*
                                  :coverage-minimum-branch *coverage-minimum-branch*))
        (format *error-output* "~&run-coverage.lisp: cl-log-kit test suite failed~%")
        (uiop:quit 1))
    (sb-ext:timeout ()
      (format *error-output*
              "~&run-coverage.lisp: exceeded ~Ds timeout -- likely a hung/deadlocked spec, see t/handler-test.lisp's thread-race specs first~%"
              *timeout-seconds*)
      (uiop:quit 1))
    (error (condition)
      (format *error-output* "~&run-coverage.lisp: ~A~%" condition)
      (uiop:quit 1)))

  (format t "~&Coverage report: ~A~%" (namestring coverage-index))
  (uiop:quit 0))
