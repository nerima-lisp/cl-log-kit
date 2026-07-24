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
        (signals invalid-log-fields (make-log-record :fields (list :cycle cycle))))))

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
