;;;; run-tests.lisp
;;;
;;; Bootstrap script: registers this repository and cl-weave with ASDF's
;;; source registry, loads the test system, and runs the suite.

(require :asdf)

(defun script-directory ()
  (make-pathname :name nil
                 :type nil
                 :defaults (or *load-truename*
                               *compile-file-truename*
                               (error "Unable to determine the script location"))))

(defparameter +cl-weave-directory+
  #P"/Users/take/ghq/github.com/nerima-lisp/cl-weave/")

(defun configure-source-registry (directories)
  (let* ((entries (mapcar (lambda (directory)
                            (format nil "~A//" (namestring directory)))
                          directories))
         (local-registry (format nil "~{~A~^:~}" entries))
         (existing-registry (uiop:getenv "CL_SOURCE_REGISTRY"))
         (source-registry (if (and existing-registry (plusp (length existing-registry)))
                              (format nil "~A:~A" local-registry existing-registry)
                              local-registry)))
    (setf (uiop:getenv "CL_SOURCE_REGISTRY") source-registry)
    (asdf:initialize-source-registry)
    source-registry))

(let ((root (script-directory)))
  (configure-source-registry (list root +cl-weave-directory+))
  (asdf:load-system "cl-log-kit/test")
  (unless (funcall (symbol-function (find-symbol "RUN-TESTS" "CL-LOG-KIT/TEST")))
    (uiop:quit 1))
  (uiop:quit 0))
