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
;;; direct experiment, not assumption. The second
;;; category is in direct, structural tension with writing more of this
;;; library's logic as DEFMACRO bodies: the more behavior a macro's
;;; generative template owns rather than the ordinary functions/methods it
;;; emits, the less of that behavior sb-cover can measure at all. Every
;;; macro in this codebase is therefore restricted to behavioral codegen
;;; (DEFHANDLE/DEFFLUSH/DEFCLOSE, DEFINE-LOG-LEVEL-MACROS,
;;; DEFINE-STREAM-HANDLER-CONSTRUCTORS, CHECK-TYPES, DEFUN-DEFAULTED,
;;; DEFMETHOD-DEFAULTED) — it emits ordinary, independently-testable
;;; functions rather than embedding runtime logic in the macro body itself,
;;; which is what keeps the measurable-code ceiling as high as it is.
;;; Converting DEFCONSTANT/DEFCLASS/DEFPACKAGE to runtime function calls
;;; purely to satisfy sb-cover was evaluated and rejected: it would regress
;;; idiom, readability, and (for the level constants) the compile-time
;;; substitution the whole design relies on, in exchange for a
;;; metric that would no longer measure anything meaningful. Raising
;;; *COVERAGE-MINIMUM-* below requires new evidence of closeable gaps,
;;; stated in the pull request and carried into the release notes, not a
;;; quiet edit here.
;;; Usage: sbcl --script run-coverage.lisp
(require :asdf)
(require :sb-cover)

;; Mirrors flake.nix's timeoutSeconds=120: that Nix-level wrapper only
;; guards `checks.default`/`apps.test`, not a direct `sbcl --script
;; run-coverage.lisp` invocation, so a hung/deadlocked spec must be caught
;; here too -- the command a contributor runs by hand and the gate CI runs
;; cannot drift apart. Scoped to the RUN-ALL call below only, not the
;; ASDF:LOAD-SYSTEM calls, so ordinary cold-compile variance while
;; instrumenting the library for coverage cannot trip it as a false positive.
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

;; Every genuinely reachable gap found by direct inspection of the per-span
;; coverage HTML has been closed:
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
;; Two structural costs explain why the expression floor is where it is
;; rather than in the 96% range the branch figure suggests, and both are
;; worth understanding before anyone reads the number as "7% untested":
;;
;;   1. CPS helper pairs. Extracting a repeated
;;      (SB-THREAD:WITH-MUTEX ((%ROTATING-HANDLER-LOCK HANDLER)) ...) or
;;      cycle-marking form into a %CALL-WITH-.../WITH-... pair moves that
;;      logic behind one more DEFMACRO body. Better code, unmeasurable body.
;;   2. Docstrings. Every one of the 101 exported LOG-KIT symbols carries
;;      one, and sb-cover counts a docstring literal as an expression it can
;;      never observe executing — the covered-expression count is untouched
;;      while the total rises. Documenting the public surface is worth more
;;      than the metric it costs.
;;
;; HANDLER.LISP's %BEGIN-STREAM-OPERATION/%END-STREAM-OPERATION pair around
;; %WRITE-HANDLER-RECORD *was* extracted into a %CALL-WITH-STREAM-OPERATION
;; helper (WRITER is a continuation, so this is CPS in substance), but
;; deliberately as a plain DEFUN rather than a %CALL-WITH-.../WITH-... macro
;; pair: a macro body would move it behind (1) above's coverage blind spot,
;; and the original rejection worried a wrapper would add a closure
;; allocation to the library's documented zero-alloc write path. Both
;; concerns are avoided the same way handler-text.lisp/handler-json.lisp's
;; own WRITER closures already are: %CALL-WITH-STREAM-OPERATION declares its
;; THUNK parameter DYNAMIC-EXTENT, and %WRITE-HANDLER-RECORD/FLUSH-HANDLER
;; each pass it a literal FLET closure with a matching DYNAMIC-EXTENT
;; declaration of their own, letting SBCL stack-allocate it. Confirmed by
;; direct measurement, not assumption: (SB-EXT:GET-BYTES-CONSED) around
;; 200,000 calls each of HANDLE-LOG-RECORD (text and JSON) and FLUSH-HANDLER
;; measured exactly 0 bytes/call, and every allocation-bound spec in
;; t/performance-test.lisp continued to pass across repeated runs.
;;
;; One specific DEFMACRO/table-dispatch conversion was evaluated during the
;; 2026 modernization pass and deliberately left as a plain function, for the
;; same reason as (1) above plus one more: it sits on a DECLARE'd hot path.
;;
;;   - SNAPSHOT.LISP's %SNAPSHOT-FIELD-VALUE dispatches on value type with a
;;     compile-time TYPECASE rather than a runtime type->handler table. The
;;     function is declared (SPEED 3) as part of the library's documented
;;     hot path; a table lookup would trade that compile-time dispatch for
;;     runtime indirection to satisfy a "data vs. logic" preference this
;;     function's performance contract does not have room for.
;;
;; If a future pass reconsiders it, re-run the multi-threaded specs in
;; t/handler-test.lisp and the allocation-bound specs in t/performance-test.lisp
;; repeatedly first — both files exist specifically to catch what a single
;; run cannot.
;;
;; The true aggregate after the 2026 modernization pass is 95.03% expression /
;; 98.51% branch (2890/3041 expressions, 331/336 branches, per
;; coverage/cover-index.html). Expression rose across the pass (dead
;; sb-thread call sites removed, the DOCUMENT-READERS consolidation cut
;; sixteen near-duplicate SETF forms to one macro invocation each, the
;; MACRO-UTILS.LISP codegen macros added in the 2026 pass emit ordinary
;; measurable functions/methods per the discipline above); branch fell
;; slightly, for two reasons rather than one regression:
;;
;;   1. HOST-KIT:PATHNAME-WITHIN-P's negative branch in
;;      %PURGE-OLD-LOG-FILES (rotating-file-handler.lisp) is new, deliberate
;;      defensive hardening from the 2026 cl-host-kit adoption: every FILE
;;      it is asked to confine already came from (DIRECTORY-FILES DIRECTORY),
;;      so it cannot fail through this call site by construction. It is kept
;;      anyway so a future caller wiring a hostile or symlinked
;;      BASE-PATHNAME into this function cannot bypass confinement merely
;;      because DIRECTORY-FILES' contract changed elsewhere; forcing that
;;      branch would mean fabricating a scenario that cannot occur through
;;      the public API rather than testing anything real.
;;   2. handler.lisp's %STREAM-STATE-CLOSING-P branch in CLOSE-HANDLER,
;;      json-encoding.lisp's non-keyword-SYMBOL and SINGLE-FLOAT dispatch
;;      clauses, and snapshot.lisp's STRING dispatch clause are unchanged
;;      logic carried over verbatim by the file splits in this same pass;
;;      the specs that exercise them still pass, but splitting each into a
;;      smaller file changed its own branch denominator enough to move the
;;      per-file percentage without any test coverage actually being lost.
;;
;; These floors sit just below the new true aggregate so ordinary
;; floating-point/platform variance in sb-cover's own accounting cannot trip
;; the gate spuriously, while still catching any real regression.
;;
;; An adversarial re-check of every uncovered/partial span (not just this
;; comment's own categories) found two more legitimately-permanent-gap
;; categories -- load-time-executed forms (DOCUMENT-READERS call sites,
;; DEFPARAMETER/DEFVAR/DEFGLOBAL inits) that sb-cover cannot observe running
;; even though they demonstrably do, and branches proven unreachable by
;; tracing the call graph rather than by insufficient testing -- plus one
;; genuinely closeable gap (SNAPSHOT.LISP's %MAKE-SNAPSHOT-CONTEXT fallback,
;; now covered by a direct-API test in t/coverage-test.lisp). It also wrote,
;; then deliberately reverted, a test for this file's own
;; HOST-KIT:PATHNAME-WITHIN-P branch (item 1 above) that monkey-patched
;; HOST-KIT:DIRECTORY-FILES via (SETF (FDEFINITION ...)) to fabricate the
;; exact scenario this comment already says cannot occur through the public
;; API -- closing the metric that way is a test-integrity smell, not a real
;; regression check, so that branch stays uncovered on purpose. See Serena
;; memory architecture/logging-hardening's "Coverage-gap taxonomy" section
;; for the full per-span evidence.
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
