;;;; t/handler-test.lisp
;;;
;;; The two built-in wire formats and the shared stream backbone: text and
;;; JSON encoding (including hostile input), and the concurrent close / flush /
;;; auto-flush lifecycle that guarantees each record is written exactly once.
(in-package #:cl-log-kit/test)

;;; A value whose printer never terminates and counts its own invocations, so
;;; a test can prove the text handler never calls an arbitrary print-object.
(defvar *hostile-printer-call-count* 0)

(defclass hostile-text-value () ())

(defmethod print-object ((value hostile-text-value) stream)
  (declare (ignore value stream))
  (incf *hostile-printer-call-count*)
  (loop))

;;; A gray-streams output stream that runs a callback on FINISH-OUTPUT, used
;;; to drive the re-entrant close/flush race tests deterministically.
(defclass finish-callback-stream (sb-gray:fundamental-character-output-stream)
  ((buffer :initform (make-string-output-stream) :reader finish-callback-buffer)
    (callback :initarg :callback :initform nil :accessor finish-callback)))

(defmethod sb-gray:stream-write-char ((stream finish-callback-stream) character)
  (write-char character (finish-callback-buffer stream)))

(defmethod sb-gray:stream-finish-output ((stream finish-callback-stream))
  (let ((callback (finish-callback stream)))
    (setf (finish-callback stream) nil)
    (when callback (funcall callback))))

(describe "handlers"
  (describe "text wire format"
    (it "text-handler emits one physical line and escapes unsafe controls"
      (let ((output
              (render-through
                'text-handler
                (make-test-record
                  :message (coerce (list #\a #\Newline (code-char #x202E)
                                         (code-char #x2066) (code-char #x200B))
                                   'string)
                  :fields (list :control
                                (coerce (list (code-char 0) (code-char 127) (code-char #x2029))
                                        'string))))))
        (expect output :to-be-single-line)
        (dolist (escape '("\\n" "\\u0000" "\\u007F" "\\u2029" "\\u202E" "\\u2066" "\\u200B"))
          (expect output :to-contain-substring escape))))

    (it "text-handler never invokes arbitrary value printers"
      (let ((*hostile-printer-call-count* 0)
            (output nil)
            (finished nil)
            (thread nil))
        (setf thread
              (sb-thread:make-thread
                (lambda ()
                  (setf output
                        (render-through 'text-handler
                                        (make-test-record
                                          :fields (list :hostile
                                                        (make-instance 'hostile-text-value)))))
                  (setf finished t))))
        (unless (sb-thread:join-thread thread :timeout 1 :default nil)
          (sb-thread:terminate-thread thread))
        (expect finished :to-be-truthy)
        (expect (= 0 *hostile-printer-call-count*) :to-be-truthy)
        (expect output :to-contain-substring "field.\"hostile\"=\"#<object>\"")))

    (it "text wire format quotes untrusted tokens and contains special arithmetic"
      (let* ((bidi (string (code-char #x202E)))
             (output
               (render-through
                 'text-handler
                 (make-test-record
                   :logger-name (concatenate 'string "root level=FATAL \" \\ / " bidi)
                   :message "message level=FATAL"
                   :fields (list "key value=forged"
                                 sb-ext:double-float-positive-infinity
                                 :complex
                                 (complex sb-ext:double-float-positive-infinity 1d0))))))
        (expect output :to-be-single-line)
        (expect output :to-contain-substring "logger=\"root level=FATAL \\\" \\\\ / \\u202E\"")
        (expect output :to-contain-substring "<non-finite-float>")
        (expect output :to-contain-substring "<non-finite-complex>"))))

  (describe "json wire format"
    (it "json-handler nests explicit objects and arrays"
      (let ((output
              (render-through
                'json-handler
                (make-test-record
                  :fields (list :payload
                                (json-object
                                  (list (cons :enabled +json-false+)
                                        (cons :missing +json-null+)
                                        (cons :items (json-array (vector 1 "two" t))))))))))
        (expect output :to-contain-substring "\"payload\":{\"enabled\":false,\"missing\":null,\"items\":[1,\"two\",true]}")))

    (it "json-handler does not infer JSON containers from ordinary lists"
      (dolist (value (list 1/2 (complex 1 2) (list 1 2) (make-hash-table)
                           sb-ext:double-float-positive-infinity))
        (signals unsupported-json-value (render-json-value value))))

    (it "json-handler rejects Unicode surrogate code points"
      (let ((surrogate (code-char #xD800)))
        (when surrogate
          (signals unsupported-json-value (render-json-value (string surrogate))))))

    (it "json-handler output parses back to the expected structure"
      ;; Assert the emitted line is well-formed JSON by parsing it with an
      ;; independent nerima-lisp parser (cl-json-kit) and checking the decoded
      ;; structure, rather than only matching substrings — this catches a
      ;; malformed object (stray comma, unquoted key) a SEARCH would miss.
      (let* ((output (render-through
                       'json-handler
                       (make-test-record :message "hi" :timestamp 42
                                         :fields (list :count 7 :name "abc" :ok t))))
             (parsed (json-kit:parse output :object-type :alist)))
        (flet ((member-of (object key) (cdr (assoc key object :test #'string=))))
          (expect (member-of parsed "message") :to-equal "hi")
          (expect (member-of parsed "level") :to-equal "INFO")
          (expect (member-of parsed "logger") :to-equal "root")
          (expect (member-of parsed "time") :to-equal 42)
          (let ((fields (member-of parsed "fields")))
            (expect (member-of fields "count") :to-equal 7)
            (expect (member-of fields "name") :to-equal "abc")
            (expect (member-of fields "ok") :to-be t)))))

    (it "json-handler keeps reserved-looking fields nested"
      (let ((output
              (render-through
                'json-handler
                (make-test-record :message "outer"
                                  :fields (list :message "inner" :timestamp 7)))))
        (expect output :to-contain-substring "\"message\":\"outer\"")
        (expect output :to-contain-substring "\"fields\":{\"message\":\"inner\",\"timestamp\":7}")))

    (it "emits finite floats as strict RFC 8259 numbers"
      (labels ((render (value)
                 (with-output-to-string (stream)
                   (log-kit::%write-json-float value stream)))
               (strict-number-p (text)
                 (and (> (length text) 0)
                      (not (find #\Space text))
                      (not (find #\d text :test #'char-equal))
                      (not (char= #\. (char text (1- (length text)))))
                      (every (lambda (character)
                               (or (digit-char-p character)
                                   (find character "+-.e" :test #'char-equal)))
                             text))))
        (dolist (value (list 0.0s0 -0.0s0 0.0f0 -0.0f0 0.0d0 -0.0d0 0.0l0 -0.0l0
                             least-positive-normalized-short-float most-positive-short-float
                             least-positive-normalized-single-float most-positive-single-float
                             least-positive-normalized-double-float most-positive-double-float
                             least-positive-normalized-long-float most-positive-long-float
                             1.0d200))
          (expect (strict-number-p (render value)) :to-be-truthy))
        (expect (string= "-0.0" (render -0.0d0)) :to-be-truthy)
        (expect (string= "0.0" (render 0.0d0)) :to-be-truthy)
        (expect (find #\e (render 1.0d200) :test #'char-equal) :to-be-truthy))))

  (describe "stream lifecycle"
    (it "built-in handlers reject input-only streams"
      (signals type-error
        (make-instance 'text-handler :stream (make-string-input-stream "x"))))

    (it "close-handler leaves non-owned streams open"
      (let* ((stream (make-string-output-stream))
             (handler (make-instance 'text-handler :stream stream :auto-flush nil)))
        (handle-log-record handler (make-test-record))
        (flush-handler handler)
        (close-handler handler)
        (expect (open-stream-p stream) :to-be-truthy)
        (signals stream-error (handle-log-record handler (make-test-record)))))

    (it "auto-flush is reentrant without deadlocking the write lock"
      (let* ((stream (make-instance 'finish-callback-stream))
             (handler (make-instance 'json-handler :stream stream))
             (finished nil)
             (thread nil))
        (setf (finish-callback stream)
              (lambda () (handle-log-record handler (make-test-record :message "nested"))))
        (setf thread
              (sb-thread:make-thread
                (lambda ()
                  (handle-log-record handler (make-test-record :message "outer"))
                  (setf finished t))))
        (unless (sb-thread:join-thread thread :timeout 1 :default nil)
          (sb-thread:terminate-thread thread))
        (expect finished :to-be-truthy)
        (expect (= 2 (count #\Newline (get-output-stream-string (finish-callback-buffer stream))))
                :to-be-truthy)))

    (it "concurrent close calls on the same handler wait for stream closure"
      (let* ((entered (sb-thread:make-semaphore :count 0))
             (release (sb-thread:make-semaphore :count 0))
             (second-returned (sb-thread:make-semaphore :count 0))
             (stream (make-instance 'finish-callback-stream))
             (handler (make-instance 'json-handler :stream stream :owns-stream t))
             (state (log-kit::%handler-stream-state handler))
             writer first-closer second-closer)
        (setf (finish-callback stream)
              (lambda ()
                (sb-thread:signal-semaphore entered)
                (sb-thread:wait-on-semaphore release)))
        (setf writer
              (sb-thread:make-thread
                (lambda () (handle-log-record handler (make-test-record :message "in-flight")) t)))
        (expect (sb-thread:wait-on-semaphore entered :timeout 1) :to-be-truthy)
        (setf first-closer (sb-thread:make-thread (lambda () (close-handler handler) t)))
        (sb-thread:with-mutex ((log-kit::%stream-state-lock state))
          (loop until (log-kit::%stream-state-closing-p state)
                do (sb-thread:condition-wait (log-kit::%stream-state-waitqueue state)
                                             (log-kit::%stream-state-lock state)
                                             :timeout 1)))
        (setf second-closer
              (sb-thread:make-thread
                (lambda ()
                  (close-handler handler)
                  (sb-thread:signal-semaphore second-returned)
                  t)))
        (expect (sb-thread:wait-on-semaphore second-returned :timeout 0.05) :to-be nil)
        (sb-thread:signal-semaphore release)
        (expect (sb-thread:join-thread writer :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:join-thread first-closer :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:join-thread second-closer :timeout 1 :default nil) :to-be-truthy)
        (expect (open-stream-p stream) :to-be nil)))

    (it "owner close blocks peer writes and waits for in-flight flush"
      (let* ((entered (sb-thread:make-semaphore :count 0))
             (release (sb-thread:make-semaphore :count 0))
             (close-returned (sb-thread:make-semaphore :count 0))
             (stream (make-instance 'finish-callback-stream))
             (owner (make-instance 'json-handler :stream stream :owns-stream t))
             (peer (make-instance 'json-handler :stream stream))
             (state (log-kit::%handler-stream-state owner))
             writer closer)
        (setf (finish-callback stream)
              (lambda ()
                (sb-thread:signal-semaphore entered)
                (sb-thread:wait-on-semaphore release)))
        (setf writer
              (sb-thread:make-thread
                (lambda () (handle-log-record peer (make-test-record :message "in-flight")) t)))
        (expect (sb-thread:wait-on-semaphore entered :timeout 1) :to-be-truthy)
        (setf closer
              (sb-thread:make-thread
                (lambda ()
                  (close-handler owner)
                  (sb-thread:signal-semaphore close-returned)
                  t)))
        (sb-thread:with-mutex ((log-kit::%stream-state-lock state))
          (unless (log-kit::%stream-state-closing-p state)
            (sb-thread:condition-wait (log-kit::%stream-state-waitqueue state)
                                      (log-kit::%stream-state-lock state)
                                      :timeout 1))
          (expect (log-kit::%stream-state-closing-p state) :to-be-truthy))
        (signals stream-error (handle-log-record peer (make-test-record :message "rejected")))
        (expect (sb-thread:wait-on-semaphore close-returned :timeout 0.05) :to-be nil)
        (sb-thread:signal-semaphore release)
        (expect (sb-thread:join-thread writer :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:join-thread closer :timeout 1 :default nil) :to-be-truthy)
        (expect (open-stream-p stream) :to-be nil)
        (signals stream-error (handle-log-record peer (make-test-record :message "closed")))))

    (it "a second owner's close waits for the first owner's in-flight physical close, twice"
      ;; Both handlers own the stream: only an owning handler's CLOSE-HANDLER
      ;; reaches the closing-p wait branches at all (a non-owning handler
      ;; always takes the immediate "not owner" clause instead).
      (let* ((entered (sb-thread:make-semaphore :count 0))
             (release (sb-thread:make-semaphore :count 0))
             (second-owner-close-returned (sb-thread:make-semaphore :count 0))
             (third-close-returned (sb-thread:make-semaphore :count 0))
             (stream (make-instance 'finish-callback-stream))
             (first-owner (make-instance 'json-handler :stream stream :owns-stream t))
             (second-owner (make-instance 'json-handler :stream stream :owns-stream t))
             (state (log-kit::%handler-stream-state first-owner))
             first-closer second-closer third-closer)
        (setf (finish-callback stream)
              (lambda ()
                (sb-thread:signal-semaphore entered)
                (sb-thread:wait-on-semaphore release)))
        (setf first-closer (sb-thread:make-thread (lambda () (close-handler first-owner) t)))
        (expect (sb-thread:wait-on-semaphore entered :timeout 1) :to-be-truthy)
        ;; First close on SECOND-OWNER: never closed before, but the stream is
        ;; mid-finalization owned by a different thread, so it must wait
        ;; rather than return early or physically close a second time.
        (setf second-closer
              (sb-thread:make-thread
                (lambda ()
                  (close-handler second-owner)
                  (sb-thread:signal-semaphore second-owner-close-returned)
                  t)))
        (sb-thread:with-mutex ((log-kit::%stream-state-lock state))
          (loop until (log-kit::%handler-closed-p second-owner)
                do (sb-thread:condition-wait (log-kit::%stream-state-waitqueue state)
                                             (log-kit::%stream-state-lock state)
                                             :timeout 1)))
        (expect (sb-thread:wait-on-semaphore second-owner-close-returned :timeout 0.05) :to-be nil)
        ;; Second close on SECOND-OWNER: already marked closed by itself, and
        ;; the stream is still mid-finalization, so this call must also wait.
        (setf third-closer
              (sb-thread:make-thread
                (lambda ()
                  (close-handler second-owner)
                  (sb-thread:signal-semaphore third-close-returned)
                  t)))
        (expect (sb-thread:wait-on-semaphore third-close-returned :timeout 0.05) :to-be nil)
        (sb-thread:signal-semaphore release)
        (expect (sb-thread:join-thread first-closer :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:join-thread second-closer :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:join-thread third-closer :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:wait-on-semaphore second-owner-close-returned :timeout 1) :to-be-truthy)
        (expect (sb-thread:wait-on-semaphore third-close-returned :timeout 1) :to-be-truthy)
        (expect (open-stream-p stream) :to-be nil)))

    (it "auto-flush write excludes a peer explicit flush"
      (let* ((entered (sb-thread:make-semaphore :count 0))
             (release (sb-thread:make-semaphore :count 0))
             (second-entered (sb-thread:make-semaphore :count 0))
             (stream (make-instance 'finish-callback-stream))
             (writer-handler (make-instance 'json-handler :stream stream))
             (peer (make-instance 'json-handler :stream stream))
             writer flusher)
        (setf (finish-callback stream)
              (lambda ()
                (sb-thread:signal-semaphore entered)
                (sb-thread:wait-on-semaphore release)))
        (setf writer
              (sb-thread:make-thread
                (lambda () (handle-log-record writer-handler (make-test-record :message "write")) t)))
        (expect (sb-thread:wait-on-semaphore entered :timeout 1) :to-be-truthy)
        (setf (finish-callback stream) (lambda () (sb-thread:signal-semaphore second-entered)))
        (setf flusher (sb-thread:make-thread (lambda () (flush-handler peer) t)))
        (expect (sb-thread:wait-on-semaphore second-entered :timeout 0.05) :to-be nil)
        (sb-thread:signal-semaphore release)
        (expect (sb-thread:join-thread writer :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:join-thread flusher :timeout 1 :default nil) :to-be-truthy)
        (expect (sb-thread:wait-on-semaphore second-entered :timeout 1) :to-be-truthy)))

    (it "owner close from finish callback is deferred without deadlock"
      (let* ((callback-entered (sb-thread:make-semaphore :count 0))
             (stream (make-instance 'finish-callback-stream))
             (owner (make-instance 'json-handler :stream stream :owns-stream t))
             writer)
        (setf (finish-callback stream)
              (lambda ()
                (sb-thread:signal-semaphore callback-entered)
                (close-handler owner)))
        (setf writer
              (sb-thread:make-thread
                (lambda () (handle-log-record owner (make-test-record :message "close")) t)))
        (expect (sb-thread:wait-on-semaphore callback-entered :timeout 1) :to-be-truthy)
        (expect (sb-thread:join-thread writer :timeout 1 :default nil) :to-be-truthy)
        (expect (open-stream-p stream) :to-be nil)))

    (it "owner close is reentrant during physical stream finalization"
      (let* ((callback-returned (sb-thread:make-semaphore :count 0))
             (stream (make-instance 'finish-callback-stream))
             (owner (make-instance 'json-handler :stream stream :owns-stream t))
             closer)
        (setf (finish-callback stream)
              (lambda ()
                (close-handler owner)
                (sb-thread:signal-semaphore callback-returned)))
        (setf closer (sb-thread:make-thread (lambda () (close-handler owner) t)))
        (unwind-protect
            (progn
              (expect (sb-thread:wait-on-semaphore callback-returned :timeout 1) :to-be-truthy)
              (expect (sb-thread:join-thread closer :timeout 1 :default nil) :to-be-truthy)
              (expect (open-stream-p stream) :to-be nil))
          (when (sb-thread:thread-alive-p closer)
            (sb-thread:terminate-thread closer)))))

    (it "handlers sharing a stream serialize complete records"
      (let* ((stream (make-string-output-stream))
             (first (make-instance 'json-handler :stream stream :auto-flush nil))
             (second (make-instance 'json-handler :stream stream :auto-flush nil))
             (threads
               (loop for handler in (list first second first second)
                     collect (sb-thread:make-thread
                               (lambda ()
                                 (loop repeat 100
                                       do (handle-log-record
                                            handler
                                            (make-test-record :message "parallel"
                                                              :fields (list :ok t))))
                                 t)))))
        (mapc (lambda (thread)
                (expect (sb-thread:join-thread thread :timeout 2 :default nil) :to-be-truthy))
              threads)
        (let ((output (get-output-stream-string stream)))
          (expect (= 400 (count #\Newline output)) :to-be-truthy)
          (expect (= 800 (count #\{ output)) :to-be-truthy)
          (expect (= 800 (count #\} output)) :to-be-truthy))))))
