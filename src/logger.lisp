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

(defvar *log-context-fields* nil
  "Dynamically scoped field snapshot used by WITH-LOG-CONTEXT.")

(defun %unix-time ()
  (- (get-universal-time) 2208988800))

(defclass logger ()
  ((name :initarg :name :reader %logger-name :initform "root")
   (handler :initarg :handler :reader logger-handler)
   (level :initarg :level :reader logger-level :initform +level-info+)
   (fields :initarg :fields :reader %logger-fields :initform nil)
   (clock :initarg :clock :reader logger-clock :initform #'%unix-time))
  (:documentation "Logging configuration and immutable contextual fields."))

(defun %validate-logger-initargs (initargs)
  (unless (%proper-list-p initargs)
    (error 'program-error))
  (loop for tail on initargs by #'cddr
        for key = (car tail)
        unless (member key '(:name :handler :level :fields :clock) :test #'eq)
          do (error 'program-error)))

(defmethod initialize-instance :around ((instance logger) &rest initargs &key (name (%constant-default "root"))
                                        (handler (%constant-default (make-instance 'text-handler)))
                                        (level (%constant-default +level-info+)) (fields (%constant-default nil))
                                        (clock (%constant-default #'%unix-time)))
  (%validate-logger-initargs initargs)
  (check-types (name string) (handler handler) (level integer) (clock function))
  (%check-field-string-length name)
  (call-next-method instance :name (copy-seq name) :handler handler :level level
                    :fields (if *logger-fields-are-snapshot* fields (plist-to-alist fields))
                    :clock clock))

(defun logger-name (logger)
  (copy-seq (%logger-name logger)))

(defun logger-fields (logger)
  (%copy-field-alist (%logger-fields logger)))

(defun make-logger (&key (name (%constant-default "root")) (handler (%constant-default (make-instance 'text-handler)))
                    (level (%constant-default +level-info+)) (fields (%constant-default nil))
                    (clock (%constant-default #'%unix-time)))
  (make-instance 'logger :name name :handler handler :level level :fields fields :clock clock))

(defun %make-logger-from-snapshot (name handler level fields clock)
  (let ((*logger-fields-are-snapshot* t))
    (make-instance 'logger :name name :handler handler :level level :fields fields :clock clock)))

(defun %merge-field-alists (overrides base)
  "Merge two field alists, keeping the first entry seen for each canonical
key: every pair in OVERRIDES, then every pair in BASE whose key OVERRIDES
did not already claim."
  (let ((seen (make-hash-table :test #'equal))
        (result nil))
    (dolist (pair overrides)
      (setf (gethash (%canonical-field-name (car pair)) seen) t)
      (push (cons (car pair) (cdr pair)) result))
    (dolist (pair base)
      (unless (gethash (%canonical-field-name (car pair)) seen)
        (push (cons (car pair) (cdr pair)) result)))
    (nreverse result)))

(defun logger-with (logger &rest fields)
  (check-type logger logger)
  (%make-logger-from-snapshot (%logger-name logger) (logger-handler logger) (logger-level logger)
                              (%merge-field-alists (plist-to-alist fields) (%logger-fields logger))
                              (logger-clock logger)))

(defun derive-logger (logger &key (name (%constant-default nil) name-p) (handler (%constant-default nil) handler-p)
                      (level (%constant-default nil) level-p) (fields (%constant-default nil) fields-p)
                      (clock (%constant-default nil) clock-p))
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
  (check-type logger logger)
  (unless (%valid-logger-name-element-p child-name)
    (error 'type-error :datum child-name
           :expected-type '(and string (satisfies %valid-logger-name-element-p))))
  (let ((combined-name-length (+ (length (%logger-name logger)) 1 (length child-name))))
    (%check-snapshot-size :string-length combined-name-length +max-log-field-string-length+)
    (derive-logger logger :name (concatenate 'string (%logger-name logger) "." child-name)
                          :fields fields)))

(defmacro with-log-context ((&rest fields) &body body)
  "Run BODY with FIELDS merged onto the dynamically scoped log context, so
every log call made anywhere in BODY (not just calls with LOGGER directly in
scope) picks them up until BODY returns."
  `(let ((*log-context-fields* (%merge-field-alists (plist-to-alist (list ,@fields))
                                                     *log-context-fields*)))
     ,@body))

(defvar *default-logger* (make-logger)
  "The dynamically scoped logger used by LOG-DEFAULT-* convenience macros.")

(defun set-default-logger (logger)
  (check-type logger logger)
  (setf *default-logger* logger))
