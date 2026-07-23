;;;; src/levels.lisp
;;;
;;; Log levels are plain integer ranks so that filtering is a simple
;;; numeric comparison (level< / level<=). Keeping a single, consistent
;;; representation (integers, not a keyword+alist lookup) avoids the kind
;;; of "two code paths disagree about what a level means" class of bug.

(in-package #:log-kit)

(defconstant +level-debug+ 0)
(defconstant +level-info+ 10)
(defconstant +level-warn+ 20)
(defconstant +level-error+ 30)
(defconstant +level-fatal+ 40)

(defparameter *level-names*
  `((,+level-debug+ . "DEBUG")
    (,+level-info+ . "INFO")
    (,+level-warn+ . "WARN")
    (,+level-error+ . "ERROR")
    (,+level-fatal+ . "FATAL")))

(defun level-name (level)
  "Return the upper-case string name for the given numeric LEVEL, falling
back to the raw level for unrecognised values."
  (let ((entry (assoc level *level-names* :test #'=)))
    (if entry
        (cdr entry)
        (princ-to-string level))))

(defun level< (a b)
  "True if level A ranks strictly below level B."
  (< a b))

(defun level<= (a b)
  "True if level A ranks at or below level B."
  (<= a b))
