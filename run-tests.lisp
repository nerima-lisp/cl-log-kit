;;;; run-tests.lisp
;;;
;;; Bootstrap script: prepends this repository to ASDF's source registry,
;;; loads the test system, and runs the suite.
(require :asdf)

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

(let ((root (script-directory)))
  (configure-source-registry root)
  (asdf:test-system "cl-log-kit")
  (uiop:quit 0))
