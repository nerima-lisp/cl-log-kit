(in-package #:cl-log-kit/test)
(describe "bounded list validation"
  (it "accepts the exact array element limit and rejects limit plus one"
    (let* ((limit log-kit::+max-log-field-array-elements+)
           (at-limit (make-list limit :initial-element nil))
           (over-limit (make-list (1+ limit) :initial-element nil)))
      (expect (length (json-array-elements (json-array at-limit)))
              :to-equal limit)
      (signals log-resource-limit-exceeded (json-array over-limit))))

  (it "bounds object and plist traversal"
    (let ((limit log-kit::+max-log-field-array-elements+))
      (signals log-resource-limit-exceeded
               (json-object (make-list (1+ limit) :initial-element nil)))
      (signals log-resource-limit-exceeded
               (plist-to-alist
                 (make-list (1+ (* 2 limit)) :initial-element nil)))))

  (it "rejects circular lists"
    (let ((cycle (list nil)))
      (setf (cdr cycle) cycle)
      (signals invalid-log-fields (json-array cycle))
      (signals invalid-log-fields (json-object cycle))
      (signals invalid-log-fields (plist-to-alist cycle))))

  (it "rejects improper lists"
    (signals invalid-log-fields (json-array (cons nil :tail)))
    (signals invalid-log-fields
             (json-object (cons (cons :key 1) :tail)))
    (signals invalid-log-fields (plist-to-alist (cons :key :tail)))))
