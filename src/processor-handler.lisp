;;;; src/processor-handler.lisp
;;;
;;; PROCESSOR-HANDLER: a composition handler that runs a chain of processor
;;; functions over each record before forwarding it to a target handler,
;;; enriching records with data no call site should have to pass explicitly
;;; (host name, process id, and the like) — the same role Monolog's processor
;;; stack plays, expressed as one more MAKE-*-HANDLER wrapper alongside
;;; FILTER-HANDLER and MULTI-HANDLER rather than a separate logger concept.
(in-package #:log-kit)

(defclass processor-handler (close-managed-handler)
  ((target :initarg :target :reader %processor-handler-target)
   (processors :initarg :processors :reader %processor-handler-processors))
  (:documentation "Runs each record through a chain of enrichment functions
before forwarding it to TARGET. See MAKE-PROCESSOR-HANDLER."))

(defmethod initialize-instance :after ((instance processor-handler) &key target
                                       (processors (%constant-default nil)))
  (declare (ignore instance))
  (check-type target handler)
  (unless (%proper-list-p processors)
    (%invalid-fields processors "processor collection must be a finite proper list"))
  (dolist (processor processors) (check-type processor function))
  (setf (slot-value instance 'processors) (copy-list processors)))

(defun make-processor-handler (target &key (processors (%constant-default nil)))
  "Build a handler that runs RECORD through each of PROCESSORS, in order,
before forwarding it to TARGET. Each processor is a function of one argument
(the record so far) returning a fields plist of data to merge in, or NIL to
contribute nothing; a later processor observes the record as already
enriched by earlier ones. Contributed fields never override a field already
present before any processor ran — including one contributed by an earlier
processor at the same canonical key only if a later processor also sets it,
in which case the later processor wins — so a processor can enrich a record
but never silently clobber real call-site or logger data."
  (make-instance 'processor-handler :target target :processors processors))

(defun %apply-log-processors (record processors)
  "Run RECORD through PROCESSORS in order, returning the resulting record.
Each processor's contributed fields are merged UNDER the fields already
present on the record it was handed, so real application data always wins;
among processors themselves, a later processor's contribution overrides an
earlier one's at the same canonical key."
  (let ((original-fields (%log-record-fields record))
        (extra nil)
        (current record))
    (dolist (processor processors current)
      (let ((contributed (funcall processor current)))
        (when contributed
          (setf extra (%merge-field-alists (plist-to-alist contributed) extra))
          (setf current (%build-log-record (log-record-level record) (log-record-message record)
                                           (log-record-timestamp record)
                                           (%merge-field-alists original-fields extra)
                                           (log-record-logger-name record))))))))

(defhandle processor-handler (handler record)
  (handle-log-record (%processor-handler-target handler)
                     (%apply-log-processors record (%processor-handler-processors handler))))

(defflush processor-handler (handler)
  (flush-handler (%processor-handler-target handler)))

(defclose processor-handler (handler)
  (close-handler (%processor-handler-target handler)))
