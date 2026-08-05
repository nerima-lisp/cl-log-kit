;;;; cl-log-kit.asd

;;;; This form comes FIRST, before any defsystem. ASDF binds *package* to
;;;; ASDF-USER only for a file it loads itself; read any other way -- a REPL
;;;; `load`, an editor evaluating the buffer, flake.nix parsing :version -- the
;;;; file is read in whatever package happens to be current. Saying it makes
;;;; the file self-contained.
(in-package #:asdf-user)

(asdf:defsystem "cl-log-kit"
  :description "SBCL-only structured logging toolkit for Common Lisp"
  :long-description "A slog-inspired (Go log/slog) structured logging toolkit built around a Handler protocol (handle-log-record) that guarantees each log record is emitted exactly once. Built on the nerima-lisp toolkit family: cl-date-kit for calendar/zone handling, cl-concurrent-kit for locking/atomics, and cl-host-kit for filesystem operations."
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :version "2.1.0"
  :homepage "https://github.com/nerima-lisp/cl-log-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-log-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-log-kit.git")
  ;; UIOP:GETENV / UIOP:SYMBOL-CALL usage in the bootstrap scripts and the
  ;; :VERSION test-op below need a modern ASDF; require it explicitly so a
  ;; stale system ASDF fails fast with a clear version error instead of a
  ;; confusing missing-function error deep in the load.
  :depends-on ((:version "asdf" "3.3.1")
               (:version "cl-date-kit" "0.3.0")
               (:version "cl-concurrent-kit" "0.5.0")
               (:version "cl-host-kit" "0.3.1"))
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "levels")
               (:file "macro-utils")
               (:file "conditions")
               (:file "limits")
               (:file "snapshot")
               (:file "fields")
               (:file "record")
               (:file "stream-state")
               (:file "handler")
               (:file "encoding")
               (:file "handler-text")
               (:file "json-encoding")
               (:file "handler-json")
               (:file "log-context")
               (:file "logger")
               (:file "lifecycle")
               (:file "simple-handlers")
               (:file "handlers")
               (:file "convenience")
               (:file "processor-handler")
               (:file "rotating-file-handler")
               (:file "buffered-handler")
               (:file "condition-logging")
               (:file "span")
               (:file "thread-context"))
  :in-order-to ((asdf:test-op (asdf:test-op "cl-log-kit/test"))))

(asdf:defsystem "cl-log-kit/test"
  :description "Test system for cl-log-kit"
  :long-description "Regression tests for the cl-log-kit public API."
  :version "2.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-log-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-log-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-log-kit.git")
  :depends-on ("cl-log-kit"
               (:version "cl-weave" "1.3.0")
               ;; Test-only: an independent nerima-lisp JSON parser used to
               ;; assert json-handler output parses back to the expected
               ;; structure, not just contains the right substrings. Its
               ;; writer is not zero-allocation and uses its own value model,
               ;; so it stays a test-only round-trip oracle rather than the
               ;; runtime json-handler's writer.
               (:version "cl-json-kit" "1.2.0"))
  :pathname "t"
  :serial t
  :components ((:file "package")
               (:file "helpers-fixtures")
               (:file "helpers-matchers")
               (:file "record-test")
               (:file "handler-test")
               (:file "handler-text-test")
               (:file "handler-json-test")
               (:file "logger-test")
               (:file "handlers-test")
               (:file "lifecycle-test")
               (:file "processor-handler-test")
               (:file "rotating-file-handler-test")
               (:file "buffered-handler-test")
               (:file "condition-logging-test")
               (:file "span-test")
               (:file "thread-context-test")
               (:file "snapshot-test")
               (:file "coverage-test")
               (:file "property-test")
               (:file "performance-test"))
  :perform (asdf:test-op
            (operation component)
            (declare (ignore operation component))
            (uiop:symbol-call :cl-log-kit/test :run-tests)))
