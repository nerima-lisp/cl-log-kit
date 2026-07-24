;;;; t/package.lisp
;;;
;;; The test package imports the real nerima-lisp/cl-weave DSL explicitly
;;; (no blanket :use, so a future cl-weave export never silently shadows a
;;; log-kit symbol). CL:DESCRIBE is shadowed in favor of CL-WEAVE:DESCRIBE,
;;; per the cl-weave installation contract.
(defpackage #:cl-log-kit/test
  (:use #:cl #:log-kit)
  (:shadowing-import-from #:cl-weave #:describe)
  (:import-from #:cl-weave
    #:it
    #:it-each
    #:it-fuzz
    #:it-property
    #:describe-each
    #:before-each
    #:after-each
    #:expect
    #:expect-not
    #:gen-boolean
    #:gen-character
    #:gen-integer
    #:gen-keyword
    #:gen-list
    #:gen-member
    #:gen-one-of
    #:gen-recursive
    #:gen-string
    #:gen-such-that
    #:gen-vector
    #:make-mock-function
    #:mock-calls
    #:clear-mock
    #:signals
    #:with-continuation-result
    #:with-continuation-values
    #:with-snapshot-updates
    #:*snapshot-directory*
    #:*snapshot-file-name*
    #:run-mutations
    #:assert-mutation-score
    #:run-all)
  (:export #:run-tests))

(in-package #:cl-log-kit/test)

(defun run-tests ()
  (unless (run-all :reporter :spec)
    (error "cl-log-kit test suite failed"))
  (format t "~&cl-log-kit/test: successful completion with 0 failures~%")
  t)
