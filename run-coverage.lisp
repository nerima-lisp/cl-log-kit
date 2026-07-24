;;;; run-coverage.lisp
;;;
;;; Bootstrap script: instruments cl-log-kit with SBCL's sb-cover and runs
;;; the suite through cl-weave's native coverage gate (RUN-ALL :COVERAGE T),
;;; which fails the build if expression/branch coverage regresses below the
;;; ceiling this branch has already reached. That ceiling is not 100%: every
;;; remaining gap is a confirmed sb-cover/SBCL instrumentation artifact
;;; (constant-folded &key defaults, load-time-only defclass/defconstant
;;; forms, defmacro bodies) or code unreachable by construction (an &rest
;;; parameter can never be bound to an improper list) — see CHANGELOG.md for
;;; the line-by-line audit. Raising *COVERAGE-MINIMUM-* below requires new
;;; evidence there, not a quiet edit here.
;;; Usage: sbcl --script run-coverage.lisp
(require :asdf)
(require :sb-cover)

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

;; The exact aggregate achieved as of the last full per-span coverage audit
;; (CHANGELOG.md, "Unreleased/Internal") is 95.44% expression / 98.21%
;; branch across src/. These floors sit just below that so ordinary
;; floating-point/platform variance in sb-cover's own accounting cannot
;; trip the gate spuriously, while still catching any real regression.
(defparameter *coverage-minimum-expression* 95.0)
(defparameter *coverage-minimum-branch* 98.0)

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
      (unless (uiop:symbol-call :cl-weave :run-all
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
                                :coverage-minimum-branch *coverage-minimum-branch*)
        (format *error-output* "~&run-coverage.lisp: cl-log-kit test suite failed~%")
        (uiop:quit 1))
    (error (condition)
      (format *error-output* "~&run-coverage.lisp: ~A~%" condition)
      (uiop:quit 1)))

  (format t "~&Coverage report: ~A~%" (namestring coverage-index))
  (uiop:quit 0))
