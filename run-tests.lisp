(require :asdf)

;; Keep direct runs bounded like the Nix test wrapper.
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

(let ((root (script-directory)))
  (configure-source-registry root)
  (handler-case
      (sb-ext:with-timeout *timeout-seconds*
        (asdf:test-system "cl-log-kit"))
    (sb-ext:timeout ()
      (format *error-output*
              "~&run-tests.lisp: exceeded ~Ds timeout -- likely a hung/deadlocked spec, see t/handler-test.lisp's thread-race specs first~%"
              *timeout-seconds*)
      (uiop:quit 1)))
  (uiop:quit 0))
