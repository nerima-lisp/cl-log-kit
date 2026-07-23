;;;; cl-log-kit.asd

(asdf:defsystem "cl-log-kit"
  :description "Dependency-free, SBCL-only structured logging toolkit for Common Lisp"
  :long-description "A slog-inspired (Go log/slog) structured logging toolkit built around a
Handler protocol (handle-log-record) that guarantees each log record is emitted exactly once."
  :version "0.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-log-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-log-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-log-kit.git")
  :depends-on (:asdf)
  :pathname "src"
  :serial t
  :components
  ((:file "package")
   (:file "levels")
   (:file "record")
   (:file "handler")
   (:file "logger")
   (:file "convenience")))

(asdf:defsystem "cl-log-kit/test"
  :description "Test system for cl-log-kit"
  :long-description "Regression tests for the cl-log-kit public API."
  :version "0.1.0"
  :author "takeokunn <bararararatty@gmail.com>"
  :maintainer "takeokunn <bararararatty@gmail.com>"
  :license "MIT"
  :homepage "https://github.com/nerima-lisp/cl-log-kit"
  :bug-tracker "https://github.com/nerima-lisp/cl-log-kit/issues"
  :source-control (:git "https://github.com/nerima-lisp/cl-log-kit.git")
  :depends-on ("cl-log-kit" "cl-weave")
  :pathname "t"
  :serial t
  :components
  ((:file "package")
   (:file "handler-test")
   (:file "logger-test")))
