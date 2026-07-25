;;;; src/levels.lisp
;;;
;;; Log levels are plain integer ranks so that filtering is a simple
;;; numeric comparison (level< / level<=). Keeping a single, consistent
;;; representation (integers, not a keyword+alist lookup) avoids the kind
;;; of "two code paths disagree about what a level means" class of bug.
(in-package #:log-kit)

(defconstant +level-debug+ 0
  "Rank of the DEBUG log level: verbose, developer-facing detail.")

(defconstant +level-info+ 10
  "Rank of the INFO log level: routine, expected events.")

(defconstant +level-warn+ 20
  "Rank of the WARN log level: unexpected but recoverable conditions.")

(defconstant +level-error+ 30
  "Rank of the ERROR log level: a failure that needs attention.")

(defconstant +level-fatal+ 40
  "Rank of the FATAL log level: an unrecoverable failure.")

(defun level-name (level)
  "Return the canonical name for LEVEL. Unknown integer levels are rendered numerically."
  (case level
    (0 "DEBUG")
    (10 "INFO")
    (20 "WARN")
    (30 "ERROR")
    (40 "FATAL")
    (otherwise (princ-to-string level))))

(defun level< (a b)
  "True if level A ranks strictly below level B."
  (< a b))

(defun level<= (a b)
  "True if level A ranks at or below level B."
  (<= a b))
