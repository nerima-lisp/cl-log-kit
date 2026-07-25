;;;; t/logger-test.lisp
;;;
;;; Logger behaviour: default-logger scoping, the fixed Unix clock, immutable
;;; contextual fields, child derivation with field precedence, the generated
;;; LOG-<LEVEL> macros' lazy evaluation, and WITH-LOG-CONTEXT dynamics.
(in-package #:cl-log-kit/test)

(describe "loggers"
  (describe "default logger and emission"
    (it "emit-log accepts omitted fields and with-default-logger is scoped"
      (let* ((outer-handler (make-instance 'counting-handler))
             (inner-handler (make-instance 'counting-handler))
             (outer (make-logger :handler outer-handler))
             (inner (make-logger :handler inner-handler))
             (*default-logger* outer))
        (emit-log inner +level-info+ "without fields")
        (with-default-logger (inner) (log-default-info "scoped"))
        (expect inner-handler :to-have-recorded 2)
        (expect outer-handler :to-have-recorded 0)
        (expect (eq *default-logger* outer) :to-be-truthy)))

    (it "default logger clocks return Unix seconds"
      (let* ((unix-now (- (get-universal-time) 2208988800))
             (actual (funcall (logger-clock (make-logger)))))
        (expect (<= (abs (- actual unix-now)) 1) :to-be-truthy)
        (expect (< actual 2000000000) :to-be-truthy)))

    (it "supports arbitrary levels without evaluating filtered payloads"
      (multiple-value-bind (logger handler) (counting-logger :level 50)
        (let ((logger-count 0) (level-count 0) (payload-count 0))
          (log-kit::log (progn (incf logger-count) logger)
               (progn (incf level-count) 49)
               (progn (incf payload-count) "hidden")
               :value (incf payload-count))
          (expect (= logger-count 1) :to-be-truthy)
          (expect (= level-count 1) :to-be-truthy)
          (expect (= payload-count 0) :to-be-truthy)
          (log-kit::log logger 50 "visible" :value 7)
          (expect handler :to-have-recorded 1)))))

  (describe "contextual fields"
    (it "logger-with overrides canonical keys without duplicates"
      (let* ((base (make-logger :fields '(:service "old" :region "east")))
             (child (logger-with base "SERVICE" "new" :request-id 7))
             (fields (logger-fields child)))
        (expect (= (count-if (lambda (pair) (string-equal (string (car pair)) "service"))
                             fields)
                   1)
                :to-be-truthy)
        (expect fields :to-have-field "SERVICE" "new")
        (expect (logger-fields base) :to-have-field :service "old")))

    (it "event fields override context and invoke the handler once"
      (multiple-value-bind (logger handler) (counting-logger :fields '(:service "old"))
        (emit-log logger +level-info+ "event" '(:service "new" :id 7))
        (expect handler :to-have-recorded 1)
        (let ((fields (latest-fields handler)))
          (expect (= (count-if (lambda (pair) (string-equal (string (car pair)) "service"))
                               fields)
                     1)
                  :to-be-truthy)
          (expect fields :to-have-field :service "new"))))

    (it "derives child loggers and applies field precedence"
      (multiple-value-bind (base handler)
          (counting-logger :name "service" :fields '(:scope "logger" :base t))
        (let ((child (logger-child base "worker" :child t)))
          (expect (string= (logger-name child) "service.worker") :to-be-truthy)
          (signals type-error (logger-child base ""))
          (with-log-context (:scope "outer" :outer t)
            (with-log-context (:scope "inner" :inner t)
              (log-info child "event" :scope "call")))
          (let ((fields (latest-fields handler)))
            (expect fields :to-have-field :scope "call")
            (expect fields :to-have-field :base t)
            (expect fields :to-have-field :child t)
            (expect fields :to-have-field :outer t)
            (expect fields :to-have-field :inner t)))))

    (it "restores logging context after non-local exit"
      (multiple-value-bind (logger handler) (counting-logger)
        (handler-case (with-log-context (:temporary t) (error "leave context"))
          (error () nil))
        (log-info logger "after")
        (expect (latest-fields handler) :to-lack-field :temporary))))

  (describe "generated level macros"
  (it "allows ordinary CL and LOG-KIT package use"
    (let ((package-name "CL-LOG-KIT/USE-COMPATIBILITY-TEST"))
      (when (find-package package-name)
        (delete-package package-name))
      (unwind-protect
          (progn
            (eval '(defpackage #:cl-log-kit/use-compatibility-test
                     (:use #:cl #:log-kit)))
            (expect (find-package package-name) :to-be-truthy))
        (when (find-package package-name)
          (delete-package package-name)))))
  (it "explicit macros evaluate logger once and skip filtered expressions"
    (let ((logger-count 0) (value-count 0) (logger (make-logger :level +level-warn+)))
      (log-info (progn (incf logger-count) logger)
                (progn (incf value-count) "hidden")
                :value (incf value-count))
      (expect (= logger-count 1) :to-be-truthy)
      (expect (= value-count 0) :to-be-truthy)))
  (it "rejects a non-logger first argument instead of guessing the calling convention"
    ;; LOG-<LEVEL> always takes an explicit logger; a caller wanting the
    ;; dynamically scoped default logger must say so with LOG-DEFAULT-<LEVEL>.
    (signals type-error (log-info "message" :value 7)))
  (it "explicit and default macro families emit records"
    (multiple-value-bind (logger fetch) (capturing-logger :level +level-debug+)
      (let ((*default-logger* logger))
        (log-debug logger "explicit" :kind "debug")
        (log-default-info "default" :kind "info")
        (let ((output (funcall fetch)))
          (expect output :to-contain-substring "explicit")
          (expect output :to-contain-substring "default")))))))
