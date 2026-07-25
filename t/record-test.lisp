;;;; t/record-test.lisp
;;;
;;; The LOG-RECORD value type and the bounded, cycle-checked field snapshot:
;;; construction validation, deep isolation from caller mutation, and the
;;; resource limits that keep a single record from exhausting memory.
(in-package #:cl-log-kit/test)

;;; Catch a LOG-RESOURCE-LIMIT-EXCEEDED from THUNK, or return NIL.
(defun capture-limit (thunk)
  (handler-case (progn (funcall thunk) nil)
    (log-resource-limit-exceeded (condition) condition)))

(describe "log records"
  (describe "field plists"
    (it "rejects malformed and duplicate field plists"
      (dolist (plist (list '(:a 1 :b) (cons :a 1) '(:a 1 "A" 2)))
        (signals invalid-log-fields (plist-to-alist plist)))
      (let ((circular (list :a 1)))
        (setf (cddr circular) circular)
        (signals invalid-log-fields (plist-to-alist circular))))

    (it "rejects cycles in recursively snapshotted field values"
      (let ((cycle (list "value")))
        (setf (cdr cycle) cycle)
        (signals invalid-log-fields (make-log-record :fields (list :cycle cycle))))
      ;; Conses are walked by their own iterative spine walk; every other
      ;; container type goes through the shared WITH-SNAPSHOT-OBJECT guard,
      ;; so each one needs its own case or that guard is never exercised.
      (let ((vector (make-array 1)))
        (setf (aref vector 0) vector)
        (signals invalid-log-fields (make-log-record :fields (list :cycle vector))))
      (let ((table (make-hash-table)))
        (setf (gethash :self table) table)
        (signals invalid-log-fields (make-log-record :fields (list :cycle table))))
      (let ((vector (make-array 1)))
        (setf (aref vector 0) vector)
        (signals invalid-log-fields
          (make-log-record :fields (list :cycle (json-array vector)))))
      (let* ((object (json-object (list (cons :k 1))))
             (members (log-kit::%json-object-members object)))
        ;; Reach past the constructor's validation to plant the cycle: JSON-OBJECT
        ;; snapshots its members, so a wrapper cannot be made self-referential
        ;; through the public API alone.
        (setf (cdr (first members)) object)
        (signals invalid-log-fields (make-log-record :fields (list :cycle object))))
      ;; The same container reachable twice without being circular is a DAG and
      ;; must still snapshot cleanly.
      (let ((shared (vector 1 2)))
        (expect (log-record-fields (make-log-record :fields (list :dag (list shared shared))))
                :to-be-truthy))))

  (describe "constructor validation"
    (it "validates record and logger constructor arguments"
      (dolist (thunk (list (lambda () (make-log-record :level :info))
                           (lambda () (make-log-record :message 12))
                           (lambda () (make-log-record :logger-name 12))
                           (lambda () (make-logger :handler 12))
                           (lambda () (make-logger :clock 12))))
        (expect thunk :to-throw 'type-error)))

    (it "constructors reject unknown initargs"
      (dolist (thunk (list (lambda () (make-log-record :unknown t))
                           (lambda () (make-logger :unknown t))
                           (lambda () (make-instance 'logger :unknown t))))
        (expect thunk :to-throw 'program-error))
      (let ((cycle (list "value")))
        (setf (cdr cycle) cycle)
        (signals program-error
          (make-instance 'logger :fields cycle :%fields-snapshot t))))

    (it "%validate-logger-initargs itself rejects an unrecognized initarg"
      ;; (MAKE-INSTANCE 'LOGGER :UNKNOWN T) above is rejected by SBCL's own
      ;; MAKE-INSTANCE optimizer for a literal, compile-time-constant class
      ;; name — it never reaches INITIALIZE-INSTANCE at all, so the
      ;; PROGRAM-ERROR it signals is SBCL's own INITARG-ERROR (a
      ;; PROGRAM-ERROR subtype), not %VALIDATE-LOGGER-INITARGS's own
      ;; unknown-key guard. Driving ALLOCATE-INSTANCE and INITIALIZE-INSTANCE
      ;; directly bypasses that optimizer and reaches the real method, so
      ;; this specifically exercises %VALIDATE-LOGGER-INITARGS's own check.
      (let ((instance (allocate-instance (find-class 'logger))))
        (signals program-error (initialize-instance instance :unknown t))))

    (it "public record readers have no setf functions"
      (dolist (reader '((setf log-record-level)
                        (setf log-record-message)
                        (setf log-record-fields)))
        (expect (not (fboundp reader)) :to-be-truthy))))

  (describe "deep isolation"
    (it "record construction and readers isolate mutable data recursively"
      (let* ((message (copy-seq "hello"))
             (name (copy-seq "root"))
             (value (copy-seq "value"))
             (nested (json-object (list (cons :items (json-array (vector value))))))
             (record (make-log-record :message message :logger-name name
                                      :fields (list :key value :nested nested))))
        (setf (char message 0) #\X (char name 0) #\X (char value 0) #\X)
        (expect (string= (log-record-message record) "hello") :to-be-truthy)
        (expect (string= (log-record-logger-name record) "root") :to-be-truthy)
        (expect (log-record-fields record) :to-have-field :key "value")
        (let* ((fields (log-record-fields record))
               (object (cdr (assoc :nested fields)))
               (array (cdr (assoc :items (json-object-members object))))
               (elements (json-array-elements array)))
          (expect (string= (aref elements 0) "value") :to-be-truthy)
          (setf (char (aref elements 0) 0) #\X)
          (let* ((fresh-object (cdr (assoc :nested (log-record-fields record))))
                 (fresh-array (cdr (assoc :items (json-object-members fresh-object)))))
            (expect (string= (aref (json-array-elements fresh-array) 0) "value")
                    :to-be-truthy)))))

    (it "logger field readers return isolated copies"
      (let* ((logger (make-logger :fields '(:service "api")))
             (fields (logger-fields logger)))
        (setf (cdr (car fields)) "mutated")
        (expect (logger-fields logger) :to-have-field :service "api"))))

  (describe "resource limits"
    (it "reports deterministic snapshot resource limits"
      (let ((condition
              (capture-limit
                (lambda ()
                  (make-log-record
                    :fields (list :value
                                  (make-string (1+ log-kit::+max-log-field-string-length+))))))))
        (expect (typep condition 'log-resource-limit-exceeded) :to-be-truthy)
        (expect (eq (log-resource-limit-resource condition) :string-length) :to-be-truthy)
        (expect (= (log-resource-limit-limit condition)
                   log-kit::+max-log-field-string-length+)
                :to-be-truthy)
        (expect (= (log-resource-limit-actual condition)
                   (1+ log-kit::+max-log-field-string-length+))
                :to-be-truthy))
      (let ((oversized-name (make-string (1+ log-kit::+max-log-field-string-length+))))
        (dolist (key (list oversized-name (make-symbol oversized-name)))
          (let ((condition
                  (capture-limit (lambda () (make-log-record :fields (list key t))))))
            (expect (typep condition 'log-resource-limit-exceeded) :to-be-truthy)
            (expect (eq (log-resource-limit-resource condition) :string-length) :to-be-truthy)
            (expect (= (log-resource-limit-limit condition)
                       log-kit::+max-log-field-string-length+)
                    :to-be-truthy)
            (expect (= (log-resource-limit-actual condition) (length oversized-name))
                    :to-be-truthy))))
      (let ((condition
              (capture-limit
                (lambda ()
                  (json-array
                    (coerce (loop repeat 5
                                  collect (json-array
                                            (make-array log-kit::+max-log-field-array-elements+
                                                        :initial-element t)))
                            'vector))))))
        (expect (typep condition 'log-resource-limit-exceeded) :to-be-truthy)
        (expect (eq (log-resource-limit-resource condition) :nodes) :to-be-truthy))
      (let ((condition
              (capture-limit
                (lambda ()
                  (let ((value nil))
                    (loop repeat (+ 2 log-kit::+max-log-field-depth+)
                          do (setf value (json-array (vector value))))
                    (make-log-record :fields (list :value value)))))))
        (expect (typep condition 'log-resource-limit-exceeded) :to-be-truthy)
        (expect (eq (log-resource-limit-resource condition) :depth) :to-be-truthy)))

    (it "charges a flat list's length to the element bound, not to nesting depth"
      ;; A cons has two children, so the obvious recursive snapshot descends
      ;; into the CDR as well as the CAR — which silently redefines "nesting
      ;; depth" as "list length" and rejects an ordinary
      ;; (log-info logger "msg" :items '(1 2 ... 100)) that the equivalent
      ;; vector or JSON array accepts. These assert the three shapes agree.
      (let* ((length (* 2 log-kit::+max-log-field-depth+))
             (items (loop for index below length collect index))
             (record (make-log-record :fields (list :items items))))
        (expect (equal (cdr (assoc :items (log-record-fields record))) items) :to-be-truthy))
      (dolist (build (list (lambda (n) (loop for index below n collect index))
                           (lambda (n) (make-array n :initial-element 0))
                           (lambda (n) (json-array (loop for index below n collect index)))))
        (let ((condition
                (capture-limit
                  (lambda ()
                    (make-log-record
                      :fields (list :items
                                    (funcall build
                                             (1+ log-kit::+max-log-field-array-elements+))))))))
          (expect (typep condition 'log-resource-limit-exceeded) :to-be-truthy)
          (expect (eq (log-resource-limit-resource condition) :array-elements) :to-be-truthy)))
      ;; Genuine nesting still costs depth, and a long spine still cannot hide
      ;; a cycle: both are what the iterative walk must preserve.
      (let ((deep 0))
        (loop repeat (1+ log-kit::+max-log-field-depth+) do (setf deep (list deep)))
        (let ((condition (capture-limit (lambda () (make-log-record :fields (list :deep deep))))))
          (expect (eq (log-resource-limit-resource condition) :depth) :to-be-truthy)))
      (let ((long-cycle (loop for index below 100 collect index)))
        (setf (cdr (last long-cycle)) long-cycle)
        (signals invalid-log-fields (make-log-record :fields (list :cycle long-cycle))))
      ;; A value reachable twice without being circular is a DAG, not a cycle.
      (let* ((shared (list 1 2))
             (record (make-log-record :fields (list :pair (list shared shared)))))
        (expect (equal (cdr (assoc :pair (log-record-fields record))) '((1 2) (1 2)))
                :to-be-truthy))
      ;; A dotted tail is snapshotted like a CAR, so the shape round-trips.
      (let ((record (make-log-record :fields (list :dotted (list* 1 2 "tail")))))
        (expect (equal (cdr (assoc :dotted (log-record-fields record))) (list* 1 2 "tail"))
                :to-be-truthy)))

    (it "sizes hash-table snapshots from bounded entry counts"
      (let* ((requested-size (1+ log-kit::+max-log-field-array-elements+))
             (source (make-hash-table :size requested-size))
             (record (make-log-record :fields (list :table source)))
             (snapshot (cdr (assoc :table (log-record-fields record)))))
        (expect (> (hash-table-size source) log-kit::+max-log-field-array-elements+)
                :to-be-truthy)
        (expect (= (hash-table-count snapshot) 0) :to-be-truthy)
        (expect (< (hash-table-size snapshot) (hash-table-size source)) :to-be-truthy))
      (let ((source (make-hash-table)))
        (loop for index below (1+ log-kit::+max-log-field-array-elements+)
              do (setf (gethash index source) index))
        (let ((condition
                (capture-limit (lambda () (make-log-record :fields (list :table source))))))
          (expect (typep condition 'log-resource-limit-exceeded) :to-be-truthy)
          (expect (eq (log-resource-limit-resource condition) :hash-table-entries)
                  :to-be-truthy))))

    (it "bounds record and logger strings before copying or concatenating"
      (let* ((limit log-kit::+max-log-field-string-length+)
             (at-limit (make-string limit :initial-element #\a))
             (oversized (make-string (1+ limit) :initial-element #\a)))
        (expect (= limit (length (log-record-message (make-log-record :message at-limit))))
                :to-be-truthy)
        (let ((condition (capture-limit (lambda () (make-log-record :message oversized)))))
          (expect (typep condition 'log-resource-limit-exceeded) :to-be-truthy)
          (expect (eq :string-length (log-resource-limit-resource condition)) :to-be-truthy))
        (expect (typep (capture-limit (lambda () (make-log-record :logger-name oversized)))
                       'log-resource-limit-exceeded)
                :to-be-truthy)
        (expect (= limit (length (logger-name (make-logger :name at-limit)))) :to-be-truthy)
        (expect (typep (capture-limit (lambda () (make-logger :name oversized)))
                       'log-resource-limit-exceeded)
                :to-be-truthy)
        (let ((logger (make-logger)))
          (expect (typep (capture-limit (lambda () (derive-logger logger :name oversized)))
                         'log-resource-limit-exceeded)
                  :to-be-truthy))
        (let ((logger (make-logger :name (make-string (- limit 2) :initial-element #\a))))
          (expect (= limit (length (logger-name (logger-child logger "x")))) :to-be-truthy))
        (let ((logger (make-logger :name (make-string (1- limit) :initial-element #\a))))
          (expect (typep (capture-limit (lambda () (logger-child logger "x")))
                         'log-resource-limit-exceeded)
                  :to-be-truthy))))))
