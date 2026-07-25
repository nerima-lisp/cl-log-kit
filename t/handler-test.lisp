;;;; t/handler-test.lisp
;;;
;;; The shared stream backbone every stream-backed handler builds on: the
;;; concurrent close / flush / auto-flush lifecycle that guarantees each
;;; record is written exactly once, including the re-entrant and owner/peer
;;; races. Mirrors src/handler.lisp.
(in-package #:cl-log-kit/test)

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

  (it "rejects writes from a never-closed peer once the owner has fully closed the stream"
    ;; PEER's own HANDLER-CLOSED-P stays false (it was never closed itself),
    ;; and by the time OWNER's physical close finishes, the shared state's
    ;; CLOSING-P has already reset to nil — so this is the one combination
    ;; where %ENSURE-OPEN-HANDLER's guard can only be tripped by CLOSED-P,
    ;; with CLOSING-P proven false in the same call.
    (let* ((stream (make-string-output-stream))
           (owner (make-instance 'json-handler :stream stream :owns-stream t))
           (peer (make-instance 'json-handler :stream stream)))
      (close-handler owner)
      (expect (not (open-stream-p stream)) :to-be-truthy)
      (signals stream-error (handle-log-record peer (make-test-record)))))

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

  (it "a second reentrant close from the write-operation owner does not wait on itself"
    ;; The first reentrant CLOSE-HANDLER call (still on the write's owning
    ;; thread) marks the handler closed and defers the physical close; a
    ;; second reentrant call on that same thread must recognize it is still
    ;; the operation owner and return immediately instead of waiting for a
    ;; close that thread itself would have to complete.
    (let* ((callback-entered (sb-thread:make-semaphore :count 0))
           (stream (make-instance 'finish-callback-stream))
           (owner (make-instance 'json-handler :stream stream :owns-stream t))
           writer)
      (setf (finish-callback stream)
            (lambda ()
              (sb-thread:signal-semaphore callback-entered)
              (close-handler owner)
              (close-handler owner)))
      (setf writer
            (sb-thread:make-thread
              (lambda () (handle-log-record owner (make-test-record :message "close")) t)))
      (expect (sb-thread:wait-on-semaphore callback-entered :timeout 1) :to-be-truthy)
      (expect (sb-thread:join-thread writer :timeout 1 :default nil) :to-be-truthy)
      (expect (open-stream-p stream) :to-be nil)))

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

  (it "closing a second, not-yet-closed owner from another owner's finalization callback does not wait on itself"
    ;; SECOND-OWNER's first close call reaches CLOSE-HANDLER while CLOSING-P
    ;; is already true (set by FIRST-OWNER) and the calling thread is the
    ;; stream's FINALIZING-OWNER (it is FIRST-OWNER's own finish-callback) —
    ;; it must recognize that and return immediately rather than wait for a
    ;; finalization that same thread is in the middle of performing.
    (let* ((stream (make-instance 'finish-callback-stream))
           (first-owner (make-instance 'json-handler :stream stream :owns-stream t))
           (second-owner (make-instance 'json-handler :stream stream :owns-stream t))
           first-closer)
      (setf (finish-callback stream)
            (lambda () (close-handler second-owner)))
      (setf first-closer (sb-thread:make-thread (lambda () (close-handler first-owner) t)))
      (expect (sb-thread:join-thread first-closer :timeout 1 :default nil) :to-be-truthy)
      (expect (not (handler-open-p second-owner)) :to-be-truthy)
      (expect (open-stream-p stream) :to-be nil)))

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
        (expect (= 800 (count #\} output)) :to-be-truthy)))))
