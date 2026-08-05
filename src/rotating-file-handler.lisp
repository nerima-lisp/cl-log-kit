;;;; src/rotating-file-handler.lisp
;;;
;;; ROTATING-FILE-HANDLER: a file-backed handler that opens a fresh dated
;;; file whenever an injectable clock's "bucket" (by default today's UTC
;;; calendar date) changes, and prunes rotated files beyond a retention
;;; count — the same role Monolog's RotatingFileHandler plays. Delegates
;;; every write to a plain TEXT-HANDLER/JSON-HANDLER it owns and swaps out on
;;; rotation, rather than teaching the stream backbone in handler.lisp about
;;; rotation, so the concurrency-critical stream lifecycle code there stays
;;; unchanged.
(in-package #:log-kit)

(defun %current-log-rotation-date ()
  "The default rotation clock: today's UTC date as a zero-padded YYYY-MM-DD
string. UTC, not the host's local time zone, so a fleet spread across zones
(or simply misconfigured on one host) rotates on the same boundary
everywhere; a custom clock must also return values that sort
lexicographically in the same order as chronological order, since ordering
rotated files for retention purposes uses a plain string comparison."
  (cl-date-kit:format-local-date
   (cl-date-kit:local-date-of-instant (cl-date-kit:instant-now) (cl-date-kit:zone-offset-utc))))

(defclass rotating-file-handler (close-managed-handler)
  ((base-pathname :initarg :base-pathname :reader %rotating-handler-base-pathname)
   (max-files :initarg :max-files :initform 0 :reader %rotating-handler-max-files)
   (wire-format :initarg :wire-format :initform :text :reader %rotating-handler-wire-format)
   (auto-flush :initarg :auto-flush :initform t :reader %rotating-handler-auto-flush-p)
   (clock :initarg :clock :initform #'%current-log-rotation-date :reader %rotating-handler-clock)
   (lock :initform (cl-concurrent-kit:make-lock :name "cl-log-kit rotating-file-handler")
        :reader %rotating-handler-lock)
   (inner :initform nil :accessor %rotating-handler-inner)
   (current-bucket :initform nil :accessor %rotating-handler-current-bucket))
  (:documentation "Writes to a file derived from a base pathname and a
clock's current \"bucket\" (by default today's UTC date), opening a fresh
file and pruning old ones when the bucket changes. See
MAKE-ROTATING-FILE-HANDLER."))

(defmethod-defaulted initialize-instance :after ((instance rotating-file-handler) &key base-pathname
                                                  (max-files 0)
                                                  (wire-format :text)
                                                  (auto-flush t)
                                                  (clock #'%current-log-rotation-date))
  (check-types (base-pathname (or string pathname)) (max-files (integer 0 *)) (clock function))
  (unless (member wire-format '(:text :json))
    (error 'type-error :datum wire-format :expected-type '(member :text :json)))
  (%check-boolean-initarg auto-flush)
  (setf (slot-value instance 'base-pathname) (pathname base-pathname)))

(defun-defaulted make-rotating-file-handler (base-pathname &key (max-files 0)
                                             (wire-format :text)
                                             (auto-flush t)
                                             (clock #'%current-log-rotation-date))
  "Build a handler that writes to a file derived from BASE-PATHNAME (a
pathname or namestring) and CLOCK's current bucket, e.g. BASE-PATHNAME
\"app.log\" and bucket \"2026-07-25\" writes to \"app-2026-07-25.log\".
WIRE-FORMAT selects :TEXT (the default) or :JSON. Rotation is checked on
every write: when CLOCK's return value changes, the current file is closed
and a fresh one for the new bucket is opened. MAX-FILES bounds how many
rotated files (including the current one) are kept, oldest deleted first;
0 (the default) keeps every rotated file."
  (make-instance 'rotating-file-handler
                 :base-pathname base-pathname
                 :max-files max-files
                 :wire-format wire-format
                 :auto-flush auto-flush
                 :clock clock))

(defun %rotated-log-pathname (base-pathname bucket)
  (make-pathname :name (format nil "~A-~A" (pathname-name base-pathname) bucket)
                 :defaults base-pathname))

(defun %rotated-log-directory (base-pathname)
  "The directory rotated files for BASE-PATHNAME live in."
  (make-pathname :name nil :type nil :defaults base-pathname))

(defun %rotated-log-file-p (base-pathname pathname)
  "True when PATHNAME looks like a file %ROTATED-LOG-PATHNAME would have
written for BASE-PATHNAME: the same name prefix and, when BASE-PATHNAME has
one, the same type.

The type comparison only requires equality, not presence. An extension-less
base — \"app\", \"/var/log/myapp\" — is an ordinary thing to pass, and
%ROTATED-LOG-PATHNAME writes its rotated files with no type at all
(\"app-2026-07-25\"); requiring a NIL type to match too is what keeps that
shape recognized instead of matching every file in the directory, or none."
  (and (host-kit:string-prefix-p (format nil "~A-" (pathname-name base-pathname))
                                 (or (pathname-name pathname) ""))
       (equal (pathname-type base-pathname) (pathname-type pathname))))

(defun %open-rotation-stream-handler (wire-format pathname auto-flush)
  (let ((stream (open pathname :direction :output :if-exists :append :if-does-not-exist :create
                      :external-format :utf-8)))
    (ecase wire-format
      (:text (make-instance 'text-handler :stream stream :auto-flush auto-flush :owns-stream t))
      (:json (make-instance 'json-handler :stream stream :auto-flush auto-flush :owns-stream t)))))

(defun %purge-old-log-files (handler)
  "Delete rotated files for HANDLER beyond its MAX-FILES retention, oldest
first. A no-op when MAX-FILES is 0 (unlimited retention). Must be called
with HANDLER's lock held."
  (let ((max-files (%rotating-handler-max-files handler)))
    (when (plusp max-files)
      (let* ((base-pathname (%rotating-handler-base-pathname handler))
             (directory (%rotated-log-directory base-pathname))
             (files (sort (remove-if-not (lambda (file) (%rotated-log-file-p base-pathname file))
                                         (host-kit:directory-files directory))
                         #'string> :key #'namestring)))
        (dolist (file (nthcdr max-files files))
          ;; Confined again immediately before the delete, not just implied
          ;; by having come from DIRECTORY-FILES: the check is what a hostile
          ;; or surprising BASE-PATHNAME (a symlinked log directory, say)
          ;; cannot bypass merely by changing what DIRECTORY-FILES returned.
          (when (host-kit:pathname-within-p file directory)
            (host-kit:delete-file-if-exists file)))))))

(define-handler-lock %call-with-rotating-handler-lock with-rotating-handler-lock %rotating-handler-lock)

(defun %ensure-current-rotation (handler)
  "Return HANDLER's inner stream handler for the current clock bucket,
rotating first if the bucket has changed since the last write. Must be
called with HANDLER's lock held."
  (let ((bucket (funcall (%rotating-handler-clock handler))))
    (check-type bucket string)
    (unless (equal bucket (%rotating-handler-current-bucket handler))
      (let ((old (%rotating-handler-inner handler)))
        (when old (close-handler old)))
      (setf (%rotating-handler-inner handler)
            (%open-rotation-stream-handler
             (%rotating-handler-wire-format handler)
             (%rotated-log-pathname (%rotating-handler-base-pathname handler) bucket)
             (%rotating-handler-auto-flush-p handler))
            (%rotating-handler-current-bucket handler) bucket)
      (%purge-old-log-files handler)))
  (%rotating-handler-inner handler))

(defhandle rotating-file-handler (handler record)
  (with-rotating-handler-lock (handler)
    (handle-log-record (%ensure-current-rotation handler) record)))

(defflush rotating-file-handler (handler)
  (with-rotating-handler-lock (handler)
    (when (%rotating-handler-inner handler)
      (flush-handler (%rotating-handler-inner handler)))))

(defclose rotating-file-handler (handler)
  (with-rotating-handler-lock (handler)
    (when (%rotating-handler-inner handler)
      (close-handler (%rotating-handler-inner handler)))))
