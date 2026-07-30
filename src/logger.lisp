;;;; src/logger.lisp
;;;
;;; LOGGER: the immutable configuration and contextual fields a log call
;;; reads from. LOGGER-WITH / DERIVE-LOGGER / LOGGER-CHILD all build a new
;;; logger from an old one rather than mutating in place.
(in-package #:log-kit)

;;; Bound only around %MAKE-LOGGER-FROM-SNAPSHOT, where FIELDS is already a
;;; snapshotted alist and re-snapshotting it through PLIST-TO-ALIST would be
;;; both wrong (it is not a plist) and wasted work.
(defvar *logger-fields-are-snapshot* nil)

(defun %unix-time ()
  (- (get-universal-time) 2208988800))

(defclass logger ()
  ((name :initarg :name :reader %logger-name :initform "root")
   (handler :initarg :handler :reader logger-handler
            :documentation "The handler every log call on this logger emits through.")
   (level :initarg :level :reader logger-level :initform +level-info+
          :documentation "The minimum level rank this logger emits; see LOG-ENABLED-P.")
   (fields :initarg :fields :reader %logger-fields :initform nil)
   (clock :initarg :clock :reader logger-clock :initform #'%unix-time
          :documentation "A zero-argument function returning the timestamp for records
this logger emits."))
  (:documentation "Logging configuration and immutable contextual fields."))

(document-readers
  (logger-handler "The handler every log call on this logger emits through.")
  (logger-level "The minimum level rank this logger emits; see LOG-ENABLED-P.")
  (logger-clock "A zero-argument function returning the timestamp for records this
logger emits."))

(defun %validate-logger-initargs (initargs)
  (unless (%proper-list-p initargs)
    (error 'program-error))
  (loop for tail on initargs by #'cddr
        for key = (car tail)
        unless (member key '(:name :handler :level :fields :clock) :test #'eq)
          do (error 'program-error)))

(defmethod-defaulted initialize-instance :around ((instance logger) &rest initargs
                                                   &key (name "root")
                                                   (handler (make-instance 'text-handler))
                                                   (level +level-info+)
                                                   (fields nil)
                                                   (clock #'%unix-time))
  (%validate-logger-initargs initargs)
  (check-types (name string) (handler handler) (level integer) (clock function))
  (%check-field-string-length name)
  (call-next-method instance :name (copy-seq name) :handler handler :level level
                    :fields (if *logger-fields-are-snapshot* fields (plist-to-alist fields))
                    :clock clock))

(defun logger-name (logger)
  "A fresh copy of LOGGER's dotted name."
  (copy-seq (%logger-name logger)))

(defun logger-fields (logger)
  "A fresh, recursively copied alist of LOGGER's contextual fields."
  (%copy-field-alist (%logger-fields logger)))

(defun-defaulted make-logger (&key (name "root")
                              (handler (make-instance 'text-handler))
                              (level +level-info+)
                              (fields nil)
                              (clock #'%unix-time))
  "Build a LOGGER named NAME (default \"root\"), emitting through HANDLER
(default a fresh TEXT-HANDLER on *STANDARD-OUTPUT*) at or above LEVEL
(default +LEVEL-INFO+), with contextual FIELDS (a plist) attached to every
record it emits, timestamped by CLOCK (default Unix seconds)."
  (make-instance 'logger :name name :handler handler :level level :fields fields :clock clock))

(defun %make-logger-from-snapshot (name handler level fields clock)
  (let ((*logger-fields-are-snapshot* t))
    (make-instance 'logger :name name :handler handler :level level :fields fields :clock clock)))

(defun logger-with (logger &rest fields)
  "Return a new logger like LOGGER but with FIELDS (a plist) merged over its
existing contextual fields, call-site fields winning at the same canonical
key. LOGGER itself is unchanged."
  (check-type logger logger)
  (%make-logger-from-snapshot (%logger-name logger) (logger-handler logger) (logger-level logger)
                              (%merge-field-alists (plist-to-alist fields) (%logger-fields logger))
                              (logger-clock logger)))

(defun-defaulted derive-logger (logger &key (name nil name-p)
                                (handler nil handler-p)
                                (level nil level-p)
                                (fields nil fields-p)
                                (clock nil clock-p))
  "Return a new logger like LOGGER, with each supplied keyword argument
overriding the corresponding slot; an omitted keyword keeps LOGGER's
existing value. FIELDS, when supplied, is merged over LOGGER's fields
(call-site fields winning) rather than replacing them outright."
  (check-type logger logger)
  (let ((derived-name (if name-p name (%logger-name logger)))
        (derived-handler (if handler-p handler (logger-handler logger)))
        (derived-level (if level-p level (logger-level logger)))
        (derived-clock (if clock-p clock (logger-clock logger)))
        (derived-fields (if fields-p
                            (%merge-field-alists (plist-to-alist fields) (%logger-fields logger))
                            (%logger-fields logger))))
    (check-types (derived-name string) (derived-handler handler) (derived-level integer)
                 (derived-clock function))
    (%check-field-string-length derived-name)
    (%make-logger-from-snapshot derived-name derived-handler derived-level derived-fields
                                derived-clock)))

(defun %valid-logger-name-element-p (name)
  (and (stringp name)
       (plusp (length name))
       (char/= (char name 0) #\.)
       (char/= (char name (1- (length name))) #\.)
       (null (search ".." name))))

(defun logger-child (logger child-name &rest fields)
  "Return a new logger named LOGGER's name with \".\" and CHILD-NAME appended
(e.g. \"service\" + \"worker\" -> \"service.worker\"), with FIELDS (a plist)
merged over LOGGER's contextual fields. CHILD-NAME must be non-empty and
neither start, end with, nor contain a run of \".\"."
  (check-type logger logger)
  (unless (%valid-logger-name-element-p child-name)
    (error 'type-error :datum child-name
           :expected-type '(and string (satisfies %valid-logger-name-element-p))))
  (let ((combined-name-length (+ (length (%logger-name logger)) 1 (length child-name))))
    (%check-snapshot-size :string-length combined-name-length +max-log-field-string-length+)
    (derive-logger logger :name (concatenate 'string (%logger-name logger) "." child-name)
                          :fields fields)))

(defvar *default-logger* (make-logger)
  "The dynamically scoped logger used by LOG-DEFAULT-* convenience macros.")

(defun set-default-logger (logger)
  "Replace the process-wide *DEFAULT-LOGGER* with LOGGER and return it. For a
dynamically scoped replacement instead, use WITH-DEFAULT-LOGGER."
  (check-type logger logger)
  (setf *default-logger* logger))
