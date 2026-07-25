;;;; t/rotating-file-handler-test.lisp
;;;
;;; ROTATING-FILE-HANDLER: opening a fresh dated file when the clock's
;;; bucket changes and pruning old ones beyond a retention count. Mirrors
;;; src/rotating-file-handler.lisp. Exercises real file I/O against a
;;; disposable temporary directory, mirroring the "real SB-THREAD boundary"
;;; discipline t/thread-context-test.lisp uses for real concurrency.
(in-package #:cl-log-kit/test)

(defun %call-with-fresh-log-directory (thunk)
  (let ((dir (merge-pathnames (make-pathname :directory (list :relative (string (gensym "cl-log-kit-rotation-"))))
                              (uiop:temporary-directory))))
    (ensure-directories-exist dir)
    (unwind-protect (funcall thunk dir)
      (dolist (file (directory (merge-pathnames "*.*" dir)))
        (ignore-errors (delete-file file)))
      (ignore-errors (sb-ext:delete-directory dir)))))

(defmacro with-fresh-log-directory ((dir) &body body)
  `(%call-with-fresh-log-directory (lambda (,dir) ,@body)))

(defun popping-clock (buckets)
  (let ((remaining buckets))
    (lambda () (pop remaining))))

(describe "rotating file handler"
  (it "writes to a file derived from the base pathname and the clock's bucket"
    (with-fresh-log-directory (dir)
      (let* ((base (merge-pathnames "app.log" dir))
             (handler (make-rotating-file-handler base :clock (popping-clock '("2026-07-25")))))
        (handle-log-record handler (make-log-record :message "hello"))
        (flush-handler handler)
        (let ((target (merge-pathnames "app-2026-07-25.log" dir)))
          (expect (probe-file target) :to-be-truthy)
          (expect (search "hello" (first (uiop:read-file-lines target))) :to-be-truthy))
        (close-handler handler))))

  (it "rotates to a new file when the bucket changes, keeping the old one"
    (with-fresh-log-directory (dir)
      (let* ((base (merge-pathnames "app.log" dir))
             (handler (make-rotating-file-handler
                       base :clock (popping-clock '("2026-07-24" "2026-07-24" "2026-07-25")))))
        (handle-log-record handler (make-log-record :message "day1-a"))
        (handle-log-record handler (make-log-record :message "day1-b"))
        (handle-log-record handler (make-log-record :message "day2-a"))
        (close-handler handler)
        (let ((day1 (merge-pathnames "app-2026-07-24.log" dir))
              (day2 (merge-pathnames "app-2026-07-25.log" dir)))
          (expect (= 2 (length (uiop:read-file-lines day1))) :to-be-truthy)
          (expect (= 1 (length (uiop:read-file-lines day2))) :to-be-truthy)))))

  (it "purges rotated files beyond max-files retention, oldest first"
    (with-fresh-log-directory (dir)
      (let* ((base (merge-pathnames "app.log" dir))
             (handler (make-rotating-file-handler
                       base :max-files 2
                       :clock (popping-clock '("2026-07-22" "2026-07-23" "2026-07-24" "2026-07-25")))))
        (dotimes (n 4)
          (handle-log-record handler (make-log-record :message (format nil "day~D" n))))
        (close-handler handler)
        (expect (probe-file (merge-pathnames "app-2026-07-22.log" dir)) :to-be nil)
        (expect (probe-file (merge-pathnames "app-2026-07-23.log" dir)) :to-be nil)
        (expect (probe-file (merge-pathnames "app-2026-07-24.log" dir)) :to-be-truthy)
        (expect (probe-file (merge-pathnames "app-2026-07-25.log" dir)) :to-be-truthy))))

  (it "purges retention for an extension-less base pathname too"
    ;; Every other spec here uses "app.log". A base with no type — "app",
    ;; "/var/log/myapp" — is just as ordinary, and it used to disable
    ;; retention *silently*: the writer derives "app-2026-07-22" from
    ;; :DEFAULTS (no type), while the purge glob interpolated the NIL type
    ;; into "app-*.NIL", which matches nothing. Nothing errored; the disk
    ;; just filled up forever.
    (with-fresh-log-directory (dir)
      (let* ((base (merge-pathnames "app" dir))
             (handler (make-rotating-file-handler
                       base :max-files 2
                       :clock (popping-clock '("2026-07-22" "2026-07-23" "2026-07-24" "2026-07-25")))))
        (dotimes (n 4)
          (handle-log-record handler (make-log-record :message (format nil "day~D" n))))
        (close-handler handler)
        (expect (probe-file (merge-pathnames "app-2026-07-22" dir)) :to-be nil)
        (expect (probe-file (merge-pathnames "app-2026-07-23" dir)) :to-be nil)
        (expect (probe-file (merge-pathnames "app-2026-07-24" dir)) :to-be-truthy)
        (expect (probe-file (merge-pathnames "app-2026-07-25" dir)) :to-be-truthy))))

  (it "keeps the retention glob confined to its own base pathname's shape"
    ;; The widened glob must not start sweeping up neighbouring files: an
    ;; extension-less base matches only extension-less rotations, and a
    ;; "*.log" base only ".log" ones.
    (with-fresh-log-directory (dir)
      (dolist (name '("app-2026-07-22" "app-2026-07-23.log" "other-2026-07-22"))
        (close (open (merge-pathnames name dir) :direction :output :if-does-not-exist :create)))
      (flet ((matches (base)
               (sort (mapcar #'file-namestring
                             (directory (log-kit::%rotated-log-glob (merge-pathnames base dir))))
                     #'string<)))
        (expect (matches "app") :to-equal '("app-2026-07-22"))
        (expect (matches "app.log") :to-equal '("app-2026-07-23.log")))))

  (it "writes JSON when :wire-format :json is requested"
    (with-fresh-log-directory (dir)
      (let* ((base (merge-pathnames "app.log" dir))
             (handler (make-rotating-file-handler base :wire-format :json
                                                  :clock (popping-clock '("2026-07-25")))))
        (handle-log-record handler (make-log-record :message "hello"))
        (close-handler handler)
        (let ((line (first (uiop:read-file-lines (merge-pathnames "app-2026-07-25.log" dir)))))
          (expect (search "\"message\":\"hello\"" line) :to-be-truthy)))))

  (it "rejects an unknown wire format and a non-positive-integer max-files"
    (signals type-error (make-rotating-file-handler "/tmp/app.log" :wire-format :xml))
    (signals type-error (make-rotating-file-handler "/tmp/app.log" :max-files -1)))

  (it "flushes and closes cleanly before any record has ever been written"
    (with-fresh-log-directory (dir)
      (let ((handler (make-rotating-file-handler (merge-pathnames "app.log" dir))))
        (flush-handler handler)
        (close-handler handler)
        (expect (not (handler-open-p handler)) :to-be-truthy))))

  (it "defaults optional slots for direct instance construction, using the real default clock"
    (with-fresh-log-directory (dir)
      (let ((handler (make-instance 'rotating-file-handler :base-pathname (merge-pathnames "app.log" dir))))
        (handle-log-record handler (make-log-record :message "default-clock"))
        (close-handler handler)
        (expect (directory (merge-pathnames "app-*.log" dir)) :to-be-truthy)))))
