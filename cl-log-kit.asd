;;;; cl-log-kit.asd
(asdf:defsystem "cl-log-kit"
  :description "Dependency-free, SBCL-only structured logging toolkit for Common Lisp"
  :long-description "A slog-inspired (Go log/slog) structured logging toolkit built around a Handler protocol (handle-log-record) that guarantees each log record is emitted exactly once."
  :version "1.5.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-log-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-log-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-log-kit.git")
  ;; UIOP:GETENV / UIOP:SYMBOL-CALL usage in the bootstrap scripts and the
  ;; :VERSION test-op below need a modern ASDF; require it explicitly so a
  ;; stale system ASDF fails fast with a clear version error instead of a
  ;; confusing missing-function error deep in the load.
  :depends-on ((:version "asdf" "3.3.1"))
  :pathname "src"
  :serial t
  :components ((:file "package")
               (:file "levels")
               (:file "conditions")
               (:file "snapshot")
               (:file "record")
               (:file "handler")
               (:file "handler-text")
               (:file "handler-json")
               (:file "logger")
               (:file "lifecycle")
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
  :version "1.5.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-log-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-log-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-log-kit.git")
  :depends-on ("cl-log-kit"
               (:version "cl-weave" "0.11.0")
               ;; Test-only: an independent nerima-lisp JSON parser used to
               ;; assert json-handler output parses back to the expected
               ;; structure, not just contains the right substrings. The
               ;; shipped cl-log-kit system stays dependency-free.
               (:version "cl-json-kit" "0.3.0"))
  :pathname "t"
  :serial t
  :components ((:file "package")
               (:file "support")
               (:file "matchers")
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
