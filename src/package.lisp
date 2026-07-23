;;;; src/package.lisp

(defpackage #:log-kit
  (:use #:cl)
  (:export
   ;; levels
   #:+level-debug+
   #:+level-info+
   #:+level-warn+
   #:+level-error+
   #:+level-fatal+
   ;; log-record
   #:log-record
   #:make-log-record
   #:log-record-level
   #:log-record-message
   #:log-record-timestamp
   #:log-record-fields
   #:log-record-logger-name
   ;; handler protocol
   #:handler
   #:handle-log-record
   #:text-handler
   #:json-handler
   ;; logger
   #:logger
   #:make-logger
   #:logger-with
   #:logger-name
   #:logger-level
   #:logger-fields
   #:logger-clock
   #:logger-handler
   #:*default-logger*
   #:set-default-logger
   ;; convenience
   #:log-debug
   #:log-info
   #:log-warn
   #:log-error
   #:log-fatal))

(in-package #:log-kit)
