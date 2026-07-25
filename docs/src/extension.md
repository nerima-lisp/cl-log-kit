# Records and Extension

## `log-record`

`make-log-record` creates a read-only record snapshot with a level, message,
timestamp, fields, and logger name:

```lisp
(make-log-record :level +level-info+
                 :message "server started"
                 :timestamp 0
                 :fields '(:port 8080)
                 :logger-name "api")
```

Its `:fields` argument is a property list, exactly like logger and call-site
fields — it goes through the same [snapshotting and validation](fields.md)
as every other field source. Every slot is read-only, and the public readers
that return a mutable structure — `log-record-message`,
`log-record-fields`, and `log-record-logger-name` — hand back a fresh copy
(recursively so, for fields), so a caller holding a record can never observe
or cause a later mutation. `log-record-level` and `log-record-timestamp`
return the stored integers directly.

## Implementing a new handler

Subclass `handler` and specialize `handle-log-record` to add a new
destination or wire encoding:

```lisp
(defclass my-handler (handler)
  ((sink :initarg :sink :reader my-handler-sink)))

(defmethod handle-log-record ((handler my-handler) (record log-record))
  (send-to-sink (my-handler-sink handler) (render record)))
```

A stateless handler like this needs nothing else — the base `handler` class
already provides no-op `flush-handler` and `close-handler` methods, and its
`handler-open-p` method always returns true.

A **stateful** handler — one with buffers, an owned stream, or a connection
that can be closed — should additionally specialize:

```lisp
(defmethod handler-open-p ((handler my-handler))
  ...)

(defmethod flush-handler ((handler my-handler))
  ...)

(defmethod close-handler ((handler my-handler))
  ...)
```

so callers built on the handler protocol — `with-handler`, `flush-logger`,
and the [composition handlers](handlers.md#composition-and-lifecycle) — can
inspect and control the new handler's lifecycle the same way they do for
`text-handler` and `json-handler`.

The built-in composition handlers' thread-safe, admit-only-while-open,
close-exactly-once discipline is implemented on top of a
`close-managed-handler` base class and `defhandle` / `defflush` / `defclose`
helper macros in `lifecycle.lisp`; `text-handler` and `json-handler` get
their equivalent guarantees from the per-stream write lock in
`handler.lisp`. None of those are exported — they are internal
implementation, not public API. A new handler with the same
concurrency requirements needs to implement that discipline itself (or
depend on `cl-log-kit`'s internal package-qualified symbols at your own
risk); a handler used from a single thread, or one whose destination is
already safe for concurrent writers, does not need it at all.

## Injecting a deterministic clock

A logger's `:clock` initarg defaults to a function returning Unix time in
integer seconds. Inject a zero-argument function for deterministic tests
(or for a request-scoped logical clock):

```lisp
(make-logger :clock (lambda () 0))
```

The same pattern applies to [`with-log-span`](spans.md#clock-and-id-injection),
whose `:clock` and `:id-source` keywords default to a monotonic clock and a
gensym-derived ID generator, respectively.
