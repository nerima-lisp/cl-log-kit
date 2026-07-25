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

;; The exact aggregate achieved as of the 1.7.0 audit (CHANGELOG.md) is
;; 96.32% expression / 98.77% branch across src/, closing every genuinely
;; reachable gap found by direct inspection of the per-span coverage HTML:
;; the bignum fallback in %WRITE-INTEGER, %VALIDATE-LOGGER-INITARGS's
;; improper-list guard, the BOM/LS/PS/lone-surrogate escape branches and the
;; plain-non-ASCII passthrough branch in both wire formats, a non-keyword
;; symbol used as a raw JSON key, and the non-simple-string branch in both
;; encoders (reachable only by calling the encoder directly, since every
;; field value is normally COPY-SEQ'd into a simple string by the snapshot
;; layer before any handler sees it — see t/coverage-test.lisp). Every
;; remaining uncovered span is the same declarative, no-runtime-execution-
;; model category already carved out project-wide (DEFCONSTANT,
;; DEFCLASS/DEFSTRUCT slot lists, DEFPACKAGE export lists, IN-PACKAGE, and
;; DEFMACRO/DEFINE-CONDITION bodies).
;;
;; Extracting rotating-file-handler.lisp's three repeated
;; (SB-THREAD:WITH-MUTEX ((%ROTATING-HANDLER-LOCK HANDLER)) ...) call sites
;; into the %CALL-WITH-ROTATING-HANDLER-LOCK/WITH-ROTATING-HANDLER-LOCK CPS
;; pair (matching WITH-BOUNDED-OUTPUT/WITH-SNAPSHOT-OBJECT's existing idiom)
;; moved that logic behind one more DEFMACRO body, costing the expression
;; floor its own small, unavoidable share of the declarative-overhead
;; category above — 96.19% was the true aggregate at that point.
;;
;; Giving every one of the 101 exported LOG-KIT symbols a docstring (2.0.0;
;; previously 81 had none) added a large, one-time expression-coverage cost
;; with zero behavioral coverage lost: covered-expression count is unchanged
;; (2887 both before and after) while total expression count rose from 3000
;; to 3073, because a DEFUN/DEFMACRO/DEFCLASS/DEFSTRUCT docstring is a data
;; literal in the same declarative, no-runtime-execution-model category as
;; DEFCONSTANT and DEFPACKAGE export lists above — sb-cover counts it as an
;; expression but can never observe it "executing." 93.95% is the new true
;; aggregate. These floors sit just below the actual aggregate so ordinary
;; floating-point/platform variance in sb-cover's own accounting cannot trip
;; the gate spuriously, while still catching any real regression.
(defparameter *coverage-minimum-expression* 93.85)
(defparameter *coverage-minimum-branch* 98.7)

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
