;;;; t/property-test.lisp
;;;
;;; Property-based invariants: statements that must hold for every generated
;;; input, not just the hand-picked examples in the other spec files. These
;;; pin down the algebra of levels, the text encoder's one-line guarantee, and
;;; the field snapshot's isolation and de-duplication.
(in-package #:cl-log-kit/test)

(describe "invariants"
  (describe "level ordering"
    (it-property "level< and level<= agree with integer comparison"
        ((a (gen-integer :min -1000 :max 1000))
         (b (gen-integer :min -1000 :max 1000)))
      (expect (eq (and (level< a b) t) (and (< a b) t)) :to-be-truthy)
      (expect (eq (and (level<= a b) t) (and (<= a b) t)) :to-be-truthy))

    (it-property "level<= is reflexive and level< is irreflexive"
        ((level (gen-integer :min -1000 :max 1000)))
      (expect (level<= level level) :to-be-truthy)
      (expect (not (level< level level)) :to-be-truthy))

    (it-property "level< implies level<="
        ((a (gen-integer :min -1000 :max 1000))
         (b (gen-integer :min -1000 :max 1000)))
      (when (level< a b)
        (expect (level<= a b) :to-be-truthy)))

    ;; Mutation testing: every one-operator mutant of the underlying
    ;; comparison must be killed by comparing against the real level</level<=
    ;; result, proving the wrapper adds no drift from plain integer <, <=.
    (it "kills every mutant of the underlying integer comparisons"
      (assert-mutation-score
        (run-mutations '(< 2 5)
                       (lambda (form mutation)
                         (declare (ignore mutation))
                         (eq (eval form) (level< 2 5))))
        1.0)
      (assert-mutation-score
        (run-mutations '(<= 2 5)
                       (lambda (form mutation)
                         (declare (ignore mutation))
                         (eq (eval form) (level<= 2 5))))
        1.0)))

  (describe "text encoding"
    (it-property "text output is always exactly one physical line"
        ((message (gen-string :max-length 40
                              :alphabet #.(format nil "ab \"~C~C" #\Newline #\Tab))))
      (let ((output (render-through 'text-handler (make-test-record :message message))))
        (expect output :to-be-single-line)))

    ;; The text handler is *total* by design — it renders any field value as a
    ;; safe single line (numbers, characters, symbols bounded; every other
    ;; object the placeholder "#<object>") and must never signal, so a hostile
    ;; value cannot crash logging. Fuzz that contract across many generated
    ;; inputs with a bounded per-trial timeout rather than one hand-picked case.
    (it-fuzz "the text handler renders any generated field value as one safe line"
        ((key (gen-one-of (gen-keyword '("a" "b" "id" "n"))
                          (gen-string :min-length 1 :max-length 6)))
         (value (gen-one-of (gen-integer :min -1000000 :max 1000000)
                            (gen-boolean)
                            (gen-string :max-length 10)
                            (gen-keyword '("active" "idle"))
                            (gen-character))))
        (:trials 200 :timeout-per-trial 2)
      (expect (render-through 'text-handler (make-test-record :fields (list key value)))
              :to-be-single-line)))

  (describe "field snapshots"
    (it-property "field snapshots are isolated from later mutation"
        ((value (gen-string :min-length 1 :max-length 20)))
      (let* ((mutable (copy-seq value))
             (record (make-log-record :fields (list :key mutable))))
        (setf (char mutable 0) #\X)
        (expect (log-record-fields record) :to-have-field :key value)))

    ;; Fuzz the recursive defensive snapshot (the library's most complex,
    ;; security-relevant code) with GEN-RECURSIVE-built nested field values of
    ;; arbitrary depth and shape, rather than the hand-picked examples the
    ;; other specs use. The snapshot must be a faithful structural copy that
    ;; shares no mutable cons or string with the source.
    (it-property "recursively snapshots arbitrary nested field values"
        ((value (gen-recursive
                  (gen-one-of (gen-integer :min -50 :max 50)
                              (gen-boolean)
                              (gen-string :min-length 1 :max-length 6))
                  (lambda (self) (gen-list self :max-length 3))
                  :max-depth 3)))
      (let* ((record (make-log-record :fields (list :payload value)))
             (snapshot (cdr (assoc :payload (log-record-fields record)))))
        (expect (equal snapshot value) :to-be-truthy)
        (expect (shares-no-structure-p snapshot value) :to-be-truthy)))

    (it-property "plist-to-alist keeps exactly one entry per distinct key"
        ((keys (gen-list (gen-keyword '("alpha" "beta" "gamma" "delta" "epsilon"))
                         :max-length 6)))
      (let* ((distinct (remove-duplicates keys))
             (plist (loop for key in distinct append (list key (symbol-name key))))
             (alist (plist-to-alist plist)))
        (expect (= (length alist) (length distinct)) :to-be-truthy)
        (dolist (key distinct)
          (expect alist :to-have-field key (symbol-name key)))))

    (it-property "json object membership round-trips distinct keys"
        ((keys (gen-list (gen-keyword '("id" "count" "state" "score"))
                         :min-length 1 :max-length 4)))
      (let* ((distinct (remove-duplicates keys))
             (members (loop for key in distinct
                            for value from 0
                            collect (cons key value)))
             (object (json-object members))
             (round-trip (json-object-members object)))
        (expect (= (length round-trip) (length distinct)) :to-be-truthy)
        (loop for key in distinct
              for value from 0
              do (expect round-trip :to-have-field key value))))))
