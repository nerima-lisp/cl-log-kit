;;;; src/buffered-handler.lisp
;;;
;;; BUFFERED-HANDLER: holds records back until one at or above a trigger
;;; level arrives, then forwards the whole held-back run — including the
;;; triggering record — to a target handler in order, the same role
;;; Monolog's FingersCrossedHandler plays: stay quiet through routine
;;; DEBUG/INFO traffic, but reveal the context leading up to an ERROR once
;;; one actually happens.
(in-package #:log-kit)

(defclass buffered-handler (close-managed-handler)
  ((target :initarg :target :reader %buffered-handler-target)
   (trigger-level :initarg :trigger-level :initform +level-error+
                  :reader %buffered-handler-trigger-level)
   (buffer-size :initarg :buffer-size :initform 0 :reader %buffered-handler-buffer-size)
   (stop-buffering :initarg :stop-buffering :initform t :reader %buffered-handler-stop-buffering-p)
   (lock :initform (sb-thread:make-mutex :name "cl-log-kit buffered-handler")
         :reader %buffered-handler-lock)
   (buffer :initform nil :accessor %buffered-handler-buffer)
   (buffer-count :initform 0 :accessor %buffered-handler-buffer-count)
   (activated-p :initform nil :accessor %buffered-handler-activated-p))
  (:documentation "Holds records back from TARGET until one at or above
TRIGGER-LEVEL arrives, then forwards the whole held-back run in order. See
MAKE-BUFFERED-HANDLER."))

(defmethod initialize-instance :after ((instance buffered-handler) &key target
                                       (trigger-level (%constant-default +level-error+))
                                       (buffer-size (%constant-default 0))
                                       (stop-buffering (%constant-default t)))
  (declare (ignore instance))
  (check-types (target handler) (trigger-level integer) (buffer-size (integer 0 *)))
  (%check-boolean-initarg stop-buffering))

(defun make-buffered-handler (target &key (trigger-level (%constant-default +level-error+))
                              (buffer-size (%constant-default 0))
                              (stop-buffering (%constant-default t)))
  "Build a handler that holds records back from TARGET until one at or above
TRIGGER-LEVEL (default +LEVEL-ERROR+) arrives, then forwards every held
record, oldest first, followed by the triggering one. BUFFER-SIZE bounds how
many held-back records are kept, oldest dropped first; 0 (the default)
keeps every one seen since the last flush. When STOP-BUFFERING is true (the
default), the handler stays activated and forwards every later record
directly once triggered; when false, it goes back to buffering after each
flush. FLUSH-HANDLER and CLOSE-HANDLER only affect TARGET's own buffered
output — they never force an unflushed buffer out, matching
FingersCrossedHandler's own \"only reveal on trigger\" contract: records
held back at close time are discarded, not silently emitted."
  (make-instance 'buffered-handler :target target :trigger-level trigger-level
                                   :buffer-size buffer-size :stop-buffering stop-buffering))

(defun %buffered-handler-hold (handler record)
  "Push RECORD onto HANDLER's buffer (newest first), trimming to
BUFFER-SIZE when it is positive. Must be called with HANDLER's lock held."
  (push record (%buffered-handler-buffer handler))
  (incf (%buffered-handler-buffer-count handler))
  (let ((limit (%buffered-handler-buffer-size handler)))
    (when (and (plusp limit) (> (%buffered-handler-buffer-count handler) limit))
      (setf (%buffered-handler-buffer handler) (subseq (%buffered-handler-buffer handler) 0 limit)
            (%buffered-handler-buffer-count handler) limit))))

(defun %buffered-handler-release (handler)
  "Forward every held record on HANDLER to its target, oldest first, then
empty the buffer. Must be called with HANDLER's lock held."
  (dolist (record (reverse (%buffered-handler-buffer handler)))
    (handle-log-record (%buffered-handler-target handler) record))
  (setf (%buffered-handler-buffer handler) nil
        (%buffered-handler-buffer-count handler) 0))

(defhandle buffered-handler (handler record)
  (sb-thread:with-mutex ((%buffered-handler-lock handler))
    (cond
      ((%buffered-handler-activated-p handler)
       (handle-log-record (%buffered-handler-target handler) record))
      ((>= (log-record-level record) (%buffered-handler-trigger-level handler))
       ;; The triggering record is always released regardless of
       ;; BUFFER-SIZE, which only bounds records held *while waiting* for a
       ;; trigger: trimming here would drop real context to make room for a
       ;; record about to be released anyway.
       (push record (%buffered-handler-buffer handler))
       (%buffered-handler-release handler)
       (when (%buffered-handler-stop-buffering-p handler)
         (setf (%buffered-handler-activated-p handler) t)))
      (t
       (%buffered-handler-hold handler record)))))

(defflush buffered-handler (handler)
  (flush-handler (%buffered-handler-target handler)))

(defclose buffered-handler (handler)
  (close-handler (%buffered-handler-target handler)))
