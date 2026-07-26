;;;; src/condition-logging.lisp
;;;
;;; LOG-CONDITION and its machinery: rendering a condition (and optionally its
;;; backtrace) into log fields under strict output bounds. The bounded output
;;; stream caps every rendered string via a CPS helper so a hostile or huge
;;; condition report can never exhaust memory.
(in-package #:log-kit)

(defun %check-condition-output-limit (resource limit)
  (check-type limit (integer 0 *))
  (when (> limit +max-log-field-string-length+)
    (%resource-limit-exceeded resource +max-log-field-string-length+ limit))
  limit)

(defun %bounded-string (string limit)
  (check-type limit (integer 0 *))
  (if (<= (length string) limit) string (subseq string 0 limit)))

(defclass %bounded-character-output-stream (sb-gray:fundamental-character-output-stream)
  ((buffer :initarg :buffer :reader %bounded-output-buffer)
   (limit :initarg :limit :reader %bounded-output-limit)
   (abort-tag :initarg :abort-tag :reader %bounded-output-abort-tag)))

(defmethod sb-gray:stream-write-char ((stream %bounded-character-output-stream) character)
  (let ((buffer (%bounded-output-buffer stream)))
    (when (= (fill-pointer buffer) (%bounded-output-limit stream))
      (throw (%bounded-output-abort-tag stream) nil))
    (vector-push-extend character buffer)
    character))

(defmethod sb-gray:stream-write-string ((stream %bounded-character-output-stream) string
                                        &optional (start (%constant-default 0)) end)
  (let ((end (or end (length string)))
        (buffer (%bounded-output-buffer stream)))
    (loop for index from start below end
          do (when (= (fill-pointer buffer) (%bounded-output-limit stream))
               (throw (%bounded-output-abort-tag stream) nil))
             (vector-push-extend (char string index) buffer))
    string))

(defun %call-with-bounded-output (limit body)
  "Call BODY with a character output stream capturing at most LIMIT characters,
then return the captured string. Writing past LIMIT unwinds BODY through a
private catch tag, so a caller can render an arbitrarily large object without
ever over-allocating."
  (let* ((abort-tag (gensym "BOUNDED-OUTPUT"))
         (buffer (make-array (min limit 256) :element-type 'character :adjustable t
                             :fill-pointer 0))
         (stream (make-instance '%bounded-character-output-stream :buffer buffer :limit limit
                                :abort-tag abort-tag)))
    (catch abort-tag
      (funcall body stream))
    (copy-seq buffer)))

(defmacro with-bounded-output ((stream-var limit) &body body)
  "Evaluate BODY with STREAM-VAR bound to a bounded output stream capped at
LIMIT, returning the captured string. See %CALL-WITH-BOUNDED-OUTPUT."
  `(%call-with-bounded-output ,limit (lambda (,stream-var) ,@body)))

(defun %condition-type-message (condition limit)
  (check-type condition condition)
  (%bounded-string (format nil "<condition ~A>" (string-downcase (string (type-of condition))))
                   limit))

(defun %safe-condition-message (condition limit &key (render-report (%constant-default nil))
                                (resource (%constant-default :condition-message-length)))
  (check-type condition condition)
  (check-type render-report boolean)
  (%check-condition-output-limit resource limit)
  (if (not render-report)
      (%condition-type-message condition limit)
      (handler-case
          (with-bounded-output (stream limit)
            (let ((*print-circle* nil)
                  (*print-level* 4)
                  (*print-length* 16)
                  (*print-escape* nil)
                  (*print-readably* nil))
              (princ condition stream)))
        (condition () (%bounded-string "<condition report failed>" limit)))))

(defun %capture-condition-backtrace (limit)
  (%check-condition-output-limit :condition-backtrace-length limit)
  (with-bounded-output (stream limit)
    (sb-debug:print-backtrace :stream stream :count 64)))

(defun %rendered-backtrace (backtrace limit)
  "Render an explicit :BACKTRACE argument to LOG-CONDITION: a string is
truncated as-is, any other object is rendered like a condition message."
  (if backtrace
      (if (stringp backtrace)
          (subseq backtrace 0 (min (length backtrace) limit))
          (%safe-condition-message backtrace limit :resource :condition-backtrace-length))
      (%capture-condition-backtrace limit)))

(defun %condition-fields (condition condition-message backtrace capture-backtrace backtrace-limit)
  (check-type condition condition)
  (check-type capture-backtrace boolean)
  (%check-condition-output-limit :condition-backtrace-length backtrace-limit)
  (let ((fields (list :condition-type (string-downcase (string (type-of condition)))
                      :condition-message condition-message)))
    (when (or backtrace capture-backtrace)
      (setf fields (append fields
                           (list :backtrace
                                 (%bounded-string (%rendered-backtrace backtrace backtrace-limit)
                                                  backtrace-limit)))))
    fields))

(defun condition-fields (condition &key backtrace (capture-backtrace (%constant-default nil))
                         (render-report (%constant-default nil))
                         (message-limit (%constant-default 2048))
                         (backtrace-limit (%constant-default 8192)))
  "Return a fields plist describing CONDITION: :CONDITION-TYPE, always; a
bounded :CONDITION-MESSAGE only when RENDER-REPORT is true (otherwise just
the type name, to avoid running an untrusted REPORT method by default);
and :BACKTRACE when BACKTRACE is supplied or CAPTURE-BACTRACE is true, each
bounded to MESSAGE-LIMIT/BACKTRACE-LIMIT characters. Prefer LOG-CONDITION
for actually logging a condition — it evaluates all of this lazily,
building it only when the log call's level passes the logger's filter."
  (%condition-fields condition
                     (%safe-condition-message condition message-limit :render-report render-report)
                     backtrace capture-backtrace backtrace-limit))

(defmacro log-condition (logger level condition &key message fields backtrace
                         (capture-backtrace nil) (render-report nil) (message-limit 2048)
                         (backtrace-limit 8192))
  "Log CONDITION on LOGGER at LEVEL. CONDITION, FIELDS, and BACKTRACE are
evaluated only when LEVEL passes LOGGER's filter, so an expensive condition
report is never built for a level nobody will see."
  (let ((logger-var (gensym "LOGGER"))
        (level-var (gensym "LEVEL"))
        (condition-var (gensym "CONDITION"))
        (condition-message-var (gensym "CONDITION-MESSAGE"))
        (condition-fields-var (gensym "CONDITION-FIELDS"))
        (event-fields-var (gensym "EVENT-FIELDS")))
    `(let ((,logger-var ,logger)
           (,level-var ,level))
       (when (log-enabled-p ,logger-var ,level-var)
         (let* ((,condition-var ,condition)
                (,event-fields-var ,fields)
                (,condition-message-var (%safe-condition-message ,condition-var ,message-limit
                                                                  :render-report ,render-report))
                (,condition-fields-var (%condition-fields ,condition-var ,condition-message-var
                                                          ,backtrace ,capture-backtrace
                                                          ,backtrace-limit)))
           (%emit-log-unchecked ,logger-var ,level-var ,(or message condition-message-var)
                                (%merge-field-plists ,condition-fields-var
                                                     (%without-field-keys
                                                      ,event-fields-var
                                                      '(:condition-type :condition-message
                                                        :backtrace)))))))))
