# Handlers

A handler's job is to serialize a `log-record` to some destination.
`handle-log-record` is the **only** place a handler is allowed to write
output — the structural fix for a class of bug where two unrelated code
paths in an ad-hoc logger printed the same message twice. Every built-in
handler's `handle-log-record` method performs exactly one write call.

## Text

`text-handler` writes one physical line per record:

```text
ts=... level=INFO logger="api" msg="server started" field."port"="8080" field."service"="orders"
```

Newlines, carriage returns, tabs, other control characters, DEL, U+2028,
U+2029, and bidirectional or invisible spoofing control characters in
messages, keys, or values are escaped so untrusted user data embedded in a
field can never inject a fake log line or disguise itself as one. Numbers,
characters, and symbols have bounded built-in renderings; arbitrary objects
render as the safe placeholder `#<object>` without ever invoking a
user-defined print method.

## JSON

`json-handler` writes one strict [RFC 8259](https://www.rfc-editor.org/rfc/rfc8259)
JSON object per line. The reserved top-level keys are `time`, `level`,
`logger`, and `message`; every user field is nested under a `fields` object
and can never collide with or shadow a top-level key.

Supported field values:

| Lisp value | JSON encoding |
| --- | --- |
| `nil` or `+json-null+` | `null` |
| `+json-false+` | `false` |
| `t` | `true` |
| string | string |
| integer | number |
| finite float | number |
| symbol | string (keywords are downcased) |
| `(json-object alist)` | object |
| `(json-array list-or-vector)` | array |

`json-null-p`, `json-false-p`, `json-object-p`, and `json-array-p` identify
these explicit values; `json-object-members` and `json-array-elements`
return defensive snapshots of their contents. Unsupported objects and
non-finite floats (`NaN`, infinities) signal `unsupported-json-value` rather
than being silently stringified — output either round-trips through a JSON
parser or the write never happens. The whole record is validated before any
character reaches the stream, so a rejected value can never leave a
partially written JSON object behind.

## Constructors and stream options

Both built-in handlers accept `:stream`, `:auto-flush`, and `:owns-stream`
initargs (also exposed as `make-text-handler` / `make-json-handler`
functions with the same keyword defaults):

```lisp
(make-instance 'json-handler :stream my-stream :auto-flush t :owns-stream nil)
;; equivalently:
(make-json-handler :stream my-stream :auto-flush t :owns-stream nil)
```

| Initarg | Default | Meaning |
| --- | --- | --- |
| `:stream` | `*standard-output*` | destination output stream |
| `:auto-flush` | `t` | call `finish-output` after every write |
| `:owns-stream` | `nil` | whether `close-handler` closes the stream |

Handlers that target the **same stream object** share one reentrant
stream-write lock, so their lines can never interleave, even across
multiple handler instances or threads. Each write and its automatic flush
run inside one shared operation; `flush-handler` uses the same
serialization when explicitly finishing buffered output.

`close-handler` is idempotent. It closes the underlying stream only when
`:owns-stream t`; after closing, that handler rejects further writes and
flushes with a `stream-error`. If an owned stream is closed reentrantly by a
stream callback while a write or flush is in progress, the physical close is
deferred until the outermost shared operation on that stream exits — this
avoids a self-deadlock where a callback triggered by `finish-output` tries
to close the very stream `finish-output` is still writing to.

## Composition and lifecycle

### `multi-handler`

Sends each operation — handle, flush, or close — to every child handler in
the order supplied:

```lisp
(make-multi-handler (list (make-text-handler) (make-json-handler :stream log-file))
  :error-policy :signal)
```

For **handle** and **flush**, the default `:error-policy :signal` stops the
pass at the first child that signals an error. **Close** always attempts
every child, regardless of policy, and only signals the first error (if any)
after every child has had a chance to close — so one misbehaving child can
never prevent the others from closing, and a failed close can be retried.

| `:error-policy` | Handle / flush | Close |
| --- | --- | --- |
| `:signal` (default) | abort the pass at the first error | try every child, then re-signal the first error |
| `:continue` | skip the failing child, keep going | try every child, then re-signal the first error |
| `:callback` | invoke `:error-callback`, then keep going | try every child, invoke `:error-callback`, then re-signal the first error |

`:callback` requires an `:error-callback` function, invoked with the
operation (`:handle`, `:flush`, or `:close`), the target child handler, and
the signaled condition.

### `filter-handler`

Forwards a record to its target only when a predicate accepts it; flush and
close are always forwarded unconditionally:

```lisp
(make-filter-handler (make-text-handler)
  (lambda (record) (level<= +level-warn+ (log-record-level record))))
```

### `function-handler`

Adapts a plain function as a handler — a required record callback plus
optional zero-argument flush and close callbacks:

```lisp
(make-function-handler
  (lambda (record) (push record *captured*))
  :flush-function (lambda () ...)
  :close-function (lambda () ...))
```

### `null-handler`

Discards every record. Always reports `handler-open-p` true — it has no
close protocol of its own, so it never needs to.

### `processor-handler`

Runs a record through a chain of enrichment functions before forwarding it
to a target handler — for data every record should carry (host name,
process id, and the like) without every call site passing it explicitly:

```lisp
(make-processor-handler (make-json-handler)
  :processors (list (lambda (record) (declare (ignore record))
                       (list :host (machine-instance)))
                     (lambda (record) (declare (ignore record))
                       (list :pid (sb-posix:getpid)))))
```

Each processor is a function of one argument (the record as enriched by
every earlier processor) returning a fields plist to merge in, or `nil` to
contribute nothing. Processors run in order, and a later one observes an
earlier one's contribution. Contributed fields are always merged **under**
whatever the record already carried before any processor ran — from the
original call site or its logger — so a processor can enrich a record but
never silently override real application data; among the processors
themselves, a later one overrides an earlier one at the same canonical key.

### `rotating-file-handler`

Writes to a file whose name is derived from a base pathname and a
zero-argument clock, opening a fresh file whenever the clock's value
changes:

```lisp
(make-rotating-file-handler #p"/var/log/app.log" :max-files 14)
;; writes to app-2026-07-25.log today, rotating to a new dated file
;; tomorrow and keeping at most the 14 most recent.
```

The default clock returns today's local date as `YYYY-MM-DD`, so the file
rotates once per day by default; inject any zero-argument function
returning a string that sorts lexicographically in chronological order (a
custom clock is checked on every write) for a different rotation cadence.
`:wire-format` selects `:text` (the default) or `:json`. `:max-files` bounds
how many rotated files — including the current one — are kept, oldest
deleted first; `0` (the default) keeps every one. The target directory must
already exist.

### `buffered-handler`

Holds records back until one at or above a trigger level arrives, then
releases everything held — including the triggering record — to a target
handler in order. Stays quiet through routine `DEBUG`/`INFO` traffic, but
reveals the context leading up to an error once one actually happens:

```lisp
(make-buffered-handler (make-json-handler)
  :trigger-level +level-error+ :buffer-size 100)
```

`:buffer-size` bounds how many records are held *while waiting* for a
trigger, oldest dropped first; `0` (the default) keeps every one seen since
the last release. When `:stop-buffering` is true (the default), the handler
stays activated and forwards every later record directly once triggered;
when `nil`, it goes back to buffering after each release. `flush-handler`
and `close-handler` only affect the target's own buffered output — they
never force an unreleased buffer out, so records held back when the handler
is closed without ever triggering are discarded, not silently emitted.

### Atomicity and lifecycle errors

`multi-handler` and `filter-handler` admit each handle or flush operation
atomically with respect to close: an operation admitted before close starts
is guaranteed to finish before close invokes any child handler or callback.
Once close has started, later handle and flush operations signal
`handler-lifecycle-error` **before** invoking a predicate, child handler, or
callback — so a call arriving during shutdown never partially executes.
`handler-lifecycle-error-handler`, `handler-lifecycle-error-operation`, and
`handler-lifecycle-error-state` expose the failure without parsing a report
string.

A callback must not synchronously try to close the same composition
handler while it is being handled or flushed — that self-deadlocking
request also signals `handler-lifecycle-error` rather than hanging.

### `handler-open-p`

An extensible generic function that reports whether a handler currently
accepts operations. The base `handler` method always returns true; stream
handlers and lifecycle-managed composite handlers override it to reflect
their actual state.

### `with-handler` and `flush-logger`

```lisp
(with-handler (h (make-json-handler :stream socket :owns-stream t))
  ...)
;; h's handler is closed on every exit, normal or non-local.

(flush-logger logger)
;; flushes logger's handler and returns logger.
```
