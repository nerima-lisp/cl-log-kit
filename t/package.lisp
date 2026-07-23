;;;; t/package.lisp

(defpackage #:cl-log-kit/test
  (:use #:cl #:log-kit)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave #:expect #:it #:signals #:run-all)
  (:export #:run-tests))

(in-package #:cl-log-kit/test)

(defun run-tests ()
  (unless (run-all :reporter :spec)
    (error "cl-log-kit test suite failed"))
  (format t "~&cl-log-kit/test: successful completion with 0 failures~%")
  t)
