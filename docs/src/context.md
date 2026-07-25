# Logger Derivation and Context

A `logger` is immutable configuration plus a snapshot of contextual fields.
Every derivation operation builds a **new** logger from an old one rather
than mutating in place, so a logger handed to a callee can never be changed
out from under the caller.

## `logger-with`

The fields-only derivation shortcut. Returns a new logger with the given
fields merged onto the base logger's fields; call-site fields override base
fields with the same canonical name.

```lisp
(defparameter *request-logger*
  (logger-with *logger* :request-id "abc123"))
```

## `derive-logger`

Creates a logger while optionally replacing its `:name`, `:handler`,
`:level`, or `:clock`, and merging additional `:fields`. Any keyword left
unsupplied is inherited unchanged from the source logger; supplied fields
override inherited fields with the same canonical key.

```lisp
(derive-logger *logger* :level +level-debug+ :fields '(:trace t))
```

## `logger-child`

Derives a dot-separated child name and can add fields in the same call:

```lisp
(defparameter *request-logger*
  (logger-child *logger* "requests" :component "checkout"))
;; name: "api.requests"
```

The child-name segment must be a non-empty string that does not start or end
with `.` and does not contain `..` — `logger-child` signals a `type-error`
for a segment that would produce a malformed dotted name.

## `with-log-context`

Adds dynamically scoped fields to every log call made anywhere in its body —
not just calls with a specific logger lexically in scope, but calls made by
functions further down the call stack too:

```lisp
(with-log-context (:request-id "abc123")
  (log-info *request-logger* "handling request" :attempt 2))
```

Nested `with-log-context` forms merge, with the innermost context's fields
taking precedence over the outer context's fields for the same canonical
name.

## Propagating context across threads

`with-log-context` and `*log-span-id*` (the dynamic variable
[`with-log-span`](spans.md) uses) are ordinary special variables. SBCL
threads do not inherit a parent thread's dynamic bindings, so a worker
thread spawned with `sb-thread:make-thread` — even from inside a
`with-log-context` or `with-log-span` body — starts with no context or span
id at all.

`capture-log-context` snapshots the calling thread's active context fields
and span id into an opaque `log-context-snapshot`. `with-captured-log-context`
restores that snapshot as the active state, typically inside the new
thread's body:

```lisp
(with-log-context (:request-id "abc123")
  (let ((snapshot (capture-log-context)))
    (sb-thread:make-thread
      (lambda ()
        (with-captured-log-context (snapshot)
          (log-info *logger* "handling request on a worker thread"))))))
```

Restoring a snapshot **replaces** the active context and span id rather than
merging into them: a snapshot captured before any `with-log-context` was
active restores an empty context even when `with-captured-log-context` is
used from inside one. `call-with-captured-log-context` is the underlying
function — `(call-with-captured-log-context snapshot thunk)` — for building
a custom thread-spawning helper instead of using the macro directly.

## Field precedence

When canonical field names collide across sources, precedence is, from
highest to lowest:

1. **Event fields** — the fields passed directly at the log call site
2. **Dynamic context fields** — fields from the innermost active
   `with-log-context`
3. **Logger fields** — fields baked into the logger via `make-logger`,
   `logger-with`, `derive-logger`, or `logger-child`

This is the same precedence `with-log-span` and `log-condition` use for
their own reserved fields (see [Log Spans](spans.md) and
[Logging Conditions](conditions.md)).
