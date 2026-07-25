;;;; run-coverage.lisp
;;;
;;; Bootstrap script: instruments cl-log-kit with SBCL's sb-cover and runs
;;; the suite through cl-weave's native coverage gate (RUN-ALL :COVERAGE T),
;;; which fails the build if expression/branch coverage regresses below the
;;; ceiling this branch has already reached.
;;;
;;; 100% is not the target, and is not achievable on this toolchain: every
;;; remaining gap is either a declarative form with no runtime execution
;;; model for sb-cover to observe (DEFCONSTANT, DEFCLASS/DEFSTRUCT slot
;;; lists, DEFPACKAGE export lists, IN-PACKAGE) or a DEFMACRO body, which
;;; runs only at macroexpansion time and is invisible to sb-cover's runtime
;;; STORE-COVERAGE-DATA instrumentation by construction — confirmed by
;;; direct experiment, not assumption (see CHANGELOG.md). The second
;;; category is in direct, structural tension with writing more of this
;;; library's logic as DEFMACRO bodies: the more behavior a macro's
;;; generative template owns rather than the ordinary functions/methods it
;;; emits, the less of that behavior sb-cover can measure at all. Every
;;; macro in this codebase is therefore restricted to behavioral codegen
;;; (DEFHANDLE/DEFFLUSH/DEFCLOSE, DEFINE-LOG-LEVEL-MACROS,
;;; DEFINE-STREAM-HANDLER-CONSTRUCTORS, CHECK-TYPES) — it emits ordinary,
;;; independently-testable functions rather than embedding runtime logic in
;;; the macro body itself, which is what keeps the measurable-code ceiling
;;; as high as it is. Converting DEFCONSTANT/DEFCLASS/DEFPACKAGE to runtime
;;; function calls purely to satisfy sb-cover was evaluated and rejected: it
;;; would regress idiom, readability, and (for the level constants) the
;;; compile-time substitution the whole design relies on, in exchange for a
;;; metric that would no longer measure anything meaningful. Raising
;;; *COVERAGE-MINIMUM-* below requires new evidence of closeable gaps in
;;; CHANGELOG.md, not a quiet edit here.
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
;; (CHANGELOG.md, 1.5.0) is 96.23% expression / 98.63% branch across src/.
;; processor-handler.lisp, rotating-file-handler.lisp, and
;; buffered-handler.lisp each have exactly one uncovered span beyond their
;; own IN-PACKAGE form — a DEFCLASS slot list — the same declarative,
;; no-runtime-execution-model category already carved out project-wide;
;; every function, method, and macro expansion in all three files is fully
;; exercised. These floors sit just below the actual aggregate so ordinary
;; floating-point/platform variance in sb-cover's own accounting cannot trip
;; the gate spuriously, while still catching any real regression.
(defparameter *coverage-minimum-expression* 96.1)
(defparameter *coverage-minimum-branch* 98.5)

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
