;;;; src/rotating-file-handler.lisp
;;;
;;; ROTATING-FILE-HANDLER: a file-backed handler that opens a fresh dated
;;; file whenever an injectable clock's "bucket" (by default the local
;;; calendar date) changes, and prunes rotated files beyond a retention
;;; count — the same role Monolog's RotatingFileHandler plays. Delegates
;;; every write to a plain TEXT-HANDLER/JSON-HANDLER it owns and swaps out on
;;; rotation, rather than teaching the stream backbone in handler.lisp about
;;; rotation, so the concurrency-critical stream lifecycle code there stays
;;; unchanged.
(in-package #:log-kit)

(defun %current-log-rotation-date ()
  "The default rotation clock: today's local date as a zero-padded
YYYY-MM-DD string. A custom clock must also return values that sort
lexicographically in the same order as chronological order, since ordering
rotated files for retention purposes uses a plain string comparison."
  (multiple-value-bind (second minute hour day month year) (decode-universal-time (get-universal-time))
    (declare (ignore second minute hour))
    (format nil "~4,'0D-~2,'0D-~2,'0D" year month day)))

(defclass rotating-file-handler (close-managed-handler)
  ((base-pathname :initarg :base-pathname :reader %rotating-handler-base-pathname)
   (max-files :initarg :max-files :initform 0 :reader %rotating-handler-max-files)
   (wire-format :initarg :wire-format :initform :text :reader %rotating-handler-wire-format)
   (auto-flush :initarg :auto-flush :initform t :reader %rotating-handler-auto-flush-p)
   (clock :initarg :clock :initform #'%current-log-rotation-date :reader %rotating-handler-clock)
   (lock :initform (sb-thread:make-mutex :name "cl-log-kit rotating-file-handler")
        :reader %rotating-handler-lock)
   (inner :initform nil :accessor %rotating-handler-inner)
   (current-bucket :initform nil :accessor %rotating-handler-current-bucket)))

(defmethod initialize-instance :after ((instance rotating-file-handler) &key base-pathname
                                       (max-files (%constant-default 0))
                                       (wire-format (%constant-default :text))
                                       (auto-flush (%constant-default t))
                                       (clock (%constant-default #'%current-log-rotation-date)))
  (check-types (base-pathname (or string pathname)) (max-files (integer 0 *)) (clock function))
  (unless (member wire-format '(:text :json))
    (error 'type-error :datum wire-format :expected-type '(member :text :json)))
  (%check-boolean-initarg auto-flush)
  (setf (slot-value instance 'base-pathname) (pathname base-pathname)))

(defun make-rotating-file-handler (base-pathname &key (max-files (%constant-default 0))
                                   (wire-format (%constant-default :text))
                                   (auto-flush (%constant-default t))
                                   (clock (%constant-default #'%current-log-rotation-date)))
  "Build a handler that writes to a file derived from BASE-PATHNAME (a
pathname or namestring) and CLOCK's current bucket, e.g. BASE-PATHNAME
\"app.log\" and bucket \"2026-07-25\" writes to \"app-2026-07-25.log\".
WIRE-FORMAT selects :TEXT (the default) or :JSON. Rotation is checked on
every write: when CLOCK's return value changes, the current file is closed
and a fresh one for the new bucket is opened. MAX-FILES bounds how many
rotated files (including the current one) are kept, oldest deleted first;
0 (the default) keeps every rotated file."
  (make-instance 'rotating-file-handler :base-pathname base-pathname :max-files max-files
                                        :wire-format wire-format :auto-flush auto-flush :clock clock))

(defun %rotated-log-pathname (base-pathname bucket)
  (make-pathname :name (format nil "~A-~A" (pathname-name base-pathname) bucket)
                 :defaults base-pathname))

(defun %rotated-log-glob (base-pathname)
  "A wild pathname matching every rotated file for BASE-PATHNAME. Built by
parsing a namestring rather than MAKE-PATHNAME: MAKE-PATHNAME treats a `*`
inside a plain :NAME string as a literal character to match, not a wildcard
marker, so it cannot produce a wild pathname component on its own."
  (merge-pathnames (format nil "~A-*.~A" (pathname-name base-pathname) (pathname-type base-pathname))
                   (make-pathname :name nil :type nil :defaults base-pathname)))

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
      (let* ((pattern (%rotated-log-glob (%rotating-handler-base-pathname handler)))
             (files (sort (directory pattern) #'string> :key #'namestring)))
        (dolist (file (nthcdr max-files files))
          (ignore-errors (delete-file file)))))))

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
            (%open-rotation-stream-handler (%rotating-handler-wire-format handler)
                                           (%rotated-log-pathname (%rotating-handler-base-pathname handler) bucket)
                                           (%rotating-handler-auto-flush-p handler))
            (%rotating-handler-current-bucket handler) bucket)
      (%purge-old-log-files handler)))
  (%rotating-handler-inner handler))

(defhandle rotating-file-handler (handler record)
  (sb-thread:with-mutex ((%rotating-handler-lock handler))
    (handle-log-record (%ensure-current-rotation handler) record)))

(defflush rotating-file-handler (handler)
  (sb-thread:with-mutex ((%rotating-handler-lock handler))
    (when (%rotating-handler-inner handler)
      (flush-handler (%rotating-handler-inner handler)))))

(defclose rotating-file-handler (handler)
  (sb-thread:with-mutex ((%rotating-handler-lock handler))
    (when (%rotating-handler-inner handler)
      (close-handler (%rotating-handler-inner handler)))))
