# cl-log-kit

A dependency-free, SBCL-only structured logging toolkit for Common Lisp.

`cl-log-kit` separates immutable log records from handlers that serialize
them. Each built-in handler emits a record through one
`handle-log-record` method, preventing duplicate output paths.

## Installation

Clone the repository somewhere ASDF can find it, then load the system:

```lisp
(asdf:load-system "cl-log-kit")
```

With Nix:

```sh
nix build github:nerima-lisp/cl-log-kit
```

## Usage

```lisp
(defpackage #:my-app
  (:use #:cl #:log-kit)
  (:shadowing-import-from #:log-kit #:log))
(in-package #:my-app)

(defparameter *logger*
  (make-logger
    :name "api"
    :handler (make-instance 'json-handler)
    :level +level-info+
    :fields '(:service "orders")))

(log-info *logger* "server started" :port 8080)
;; {"time":...,"level":"INFO","logger":"api","message":"server started","fields":{"port":8080,"service":"orders"}}

(defparameter *request-logger*
  (logger-with *logger* :request-id "abc123"))

(log-warn *request-logger* "slow response" :duration-ms 842)
```

`logger-with` returns a new logger. Call-site fields override logger fields
with the same case-insensitive canonical name.

### Default logger

Version 1 separates explicit-logger and default-logger calls. The
`log-debug`, `log-info`, `log-warn`, `log-error`, and `log-fatal` macros
require a logger as their first argument. Use the corresponding
`log-default-*` macro after configuring `*default-logger*`:

```lisp
(set-default-logger
  (make-logger :handler (make-instance 'text-handler)))

(log-default-error "request failed" :reason "timeout")
;; ts=... level=ERROR logger="root" msg="request failed" field."reason"="timeout"
```

Calls written as `(log-info "message")` for earlier releases must become
either `(log-info logger "message")` or `(log-default-info "message")`.
Use `with-default-logger` for a dynamically scoped default without mutating
the process-wide default:

```lisp
(with-default-logger (*request-logger*)
  (log-default-info "handling request"))
```

The low-level `(emit-log logger level message &optional fields-plist)`
function returns the emitted `log-record`, or `nil` when the level is
filtered. `set-default-logger` returns the installed logger.

Logging macros test the level before evaluating the message and field forms.
Filtered calls therefore avoid record construction, field-list allocation,
clock access, and handler work. The logger expression in an explicit call is
evaluated exactly once.

## Levels

```text
DEBUG (0) < INFO (10) < WARN (20) < ERROR (30) < FATAL (40)
```

The default threshold is `INFO`. Integer custom levels are accepted and are
rendered numerically when they do not match a standard level. `level-name`,
`level<`, and `level<=` provide the corresponding public operations.

## Fields

Logger and call-site fields are property lists:

```lisp
(make-logger :fields '(:service "api" :attempt 1))
(log-info logger "connected" :host "db.example" :tls t)
```

Keys must be symbols or strings. Property lists must be finite, proper, and
contain an even number of elements. Duplicate keys after case-insensitive
canonicalization, such as `:PORT` and `"port"`, signal
`invalid-log-fields`.

Records and loggers recursively snapshot strings, conses, arrays, hash
tables, and explicit JSON containers. Accessors return fresh snapshots, so
later mutation cannot change a record or logger. Cyclic values signal
`invalid-log-fields` instead of recursing indefinitely.

`invalid-log-fields-value`, `invalid-log-fields-reason`,
`unsupported-json-value-value`, and `unsupported-json-value-reason` expose
condition details without parsing report strings.

Recursive snapshots have fixed safety limits: depth 64, 65,536 visited
nodes, 1,048,576 characters per string, and 16,384 array elements or object
members. Exceeding a limit signals `log-resource-limit-exceeded`;
`log-resource-limit-resource`, `log-resource-limit-limit`, and
`log-resource-limit-actual` identify the failed bound.

## Logger Derivation And Context

`derive-logger` creates a logger while optionally replacing its name,
handler, level, or clock and merging additional fields. Supplied fields
override inherited fields with the same canonical key. `logger-child`
derives a dot-separated child name and can add fields:

```lisp
(defparameter *request-logger*
  (logger-child *logger* "requests" :component "checkout"))
```

`with-log-context` adds dynamically scoped fields to every log call in its
body, including calls made by functions further down the stack:

```lisp
(with-log-context (:request-id "abc123")
  (log-info *request-logger* "handling request" :attempt 2))
```

When canonical field names collide, event (call-site) fields take
precedence over dynamic context fields, which take precedence over logger
fields. `logger-with` remains available as the fields-only derivation
shortcut.

## Handlers

### Text

`text-handler` writes one physical line per record:

```text
ts=... level=INFO logger="api" msg="server started" field."port"="8080" field."service"="orders"
```

Newlines, returns, tabs, control characters, DEL, U+2028, U+2029, and
bidirectional or invisible spoofing controls in messages, keys, or values
are escaped so user data cannot inject or disguise another log line.
Numbers, characters, and symbols have bounded built-in renderings; arbitrary
objects become the safe placeholder `#<object>` without invoking a
user-defined printer.

### JSON

`json-handler` writes one JSON object per physical line. The reserved keys
are `time`, `level`, `logger`, `message`, and `fields`. User fields are
always members of the `fields` object and never appear at the top level.

Supported field values are:

- `nil` or `+json-null+`, encoded as `null`
- `+json-false+`, encoded as `false`
- `t`, encoded as `true`
- strings
- integers
- finite floats
- symbols, encoded as strings
- `(json-object alist)` for nested objects
- `(json-array list-or-vector)` for nested arrays

`json-null-p`, `json-false-p`, `json-object-p`, and `json-array-p` identify
these explicit values. `json-object-members` and `json-array-elements`
return defensive snapshots.

Unsupported objects and non-finite floats signal
`unsupported-json-value`; they are never silently stringified.

Both handlers accept `:stream`, `:auto-flush`, and `:owns-stream` initargs.
The defaults are `*standard-output*`, true, and false. Handlers targeting
the same stream share a reentrant stream operation, so their lines cannot
interleave. Each write and its automatic flush execute within one shared
operation; `flush-handler` uses the same serialization when explicitly
finishing buffered output. `close-handler` is idempotent and closes the
stream only when `:owns-stream t`; after closing, that handler rejects
writes and flushes. If an owned stream is closed reentrantly by a stream
callback during a write or flush, physical close is deferred until the
outermost shared operation exits, avoiding a self-deadlock.

### Composition And Lifecycle

`make-multi-handler` sends each operation to its handlers in the supplied
order. For handle and flush operations, its default `:error-policy :signal`
stops at the first error. Close attempts every handler before signaling the
first error, and a failed close can be retried. `:continue` proceeds with the
remaining handlers, and `:callback` invokes the required `:error-callback`
with the operation (`:handle`, `:flush`, or `:close`), target handler, and
condition before proceeding.

`make-filter-handler` forwards records accepted by its predicate and always
forwards flush and close operations. `make-function-handler` adapts a
record callback plus optional zero-argument flush and close callbacks.
`make-null-handler` discards records.

Composition handlers admit each handle or flush operation atomically. An
operation admitted before close starts finishes before close invokes child
handlers or callbacks. Once close starts, later handle and flush operations
signal `handler-lifecycle-error` before invoking a predicate, child handler,
or callback. Its `handler-lifecycle-error-handler`,
`handler-lifecycle-error-operation`, and `handler-lifecycle-error-state`
readers expose stable failure details. A callback must not synchronously
close the same composition handler while handling or flushing it; that
self-deadlocking request signals the same condition.

`handler-open-p` is an extensible generic function that reports whether a
handler accepts operations.
`with-handler` closes its handler on every exit, and `flush-logger` flushes
the logger's handler and returns the logger.

## Logging Conditions

`condition-fields` turns a condition into `:condition-type` and
`:condition-message` fields, with an optional supplied or captured
`:backtrace`. `log-condition` emits those fields and, like the other
logging macros, does not evaluate the condition or report forms when the
level is filtered:

```lisp
(handler-case
    (perform-request)
  (error (condition)
    (log-condition *logger* +level-error+ condition
      :message "request failed"
      :fields (list :request-id request-id)
      :capture-backtrace t)))
```

Explicit `:fields` are merged using the normal event precedence: event fields
override dynamic context fields, which override logger fields. The condition
keys `:condition-type`, `:condition-message`, and `:backtrace` are reserved;
values derived by `log-condition` cannot be replaced through `:fields`.

By default, condition logging does not execute an arbitrary condition report
method. It emits a safe type-based message instead. Pass `:render-report t`
to opt in to executing the report method once. The captured report output is
bounded, but the report method's CPU time and execution time are not.
Messages default to 2,048 characters and backtraces to 8,192; override these
with `:message-limit` and `:backtrace-limit`.

## Log Spans

`with-log-span` emits `:start` and `:end` records around a body:

```lisp
(with-log-span (*logger* "fetch-account"
                :level +level-info+
                :fields (list :account-id account-id))
  (fetch-account account-id))
```

Both records contain `:span-id` and `:span-event`. The end record also
contains `:span-duration` and a `:span-outcome` of `:success`, `:error`, or
`:nonlocal-exit`. Nested spans include `:parent-span-id`, and log records
inside a span inherit the current span ID through the logging context.
Span lifecycle keys are reserved and cannot be replaced through `:fields`.

The default duration clock is monotonic. Deterministic callers can inject
zero-argument `:clock` and `:id-source` functions. When the span level is
filtered, its name, fields, clock, and ID source are not evaluated; the body
still runs normally.

## Records And Extension

`make-log-record` creates a read-only record snapshot with level, message,
timestamp, fields, and logger name. Its `:fields` argument is a property
list, like logger and call-site fields.

Implement a new destination or encoding by subclassing `handler` and
specializing `handle-log-record`. Stateful handlers should also specialize
`handler-open-p`, `flush-handler`, and `close-handler` so callers can inspect
and control their lifecycle:

```lisp
(defmethod handle-log-record ((handler my-handler) (record log-record))
  ...)

(defmethod handler-open-p ((handler my-handler))
  ...)

(defmethod flush-handler ((handler my-handler))
  ...)

(defmethod close-handler ((handler my-handler))
  ...)
```

The logger's `:clock` initarg defaults to Unix time in integer seconds.
Inject a zero-argument function that returns integer Unix seconds for
deterministic tests:

```lisp
(make-logger :clock (lambda () 0))
```

## Testing

Tests depend on [`cl-weave`](https://github.com/nerima-lisp/cl-weave); point
`CL_SOURCE_REGISTRY` at both repositories, or use the flake, which wires this
up automatically. Both are test/dev-only dependencies — the `cl-log-kit`
system itself stays dependency-free.

### Recommended: `run-ci.lisp`

`run-ci.lisp` runs `run-tests.lisp` or `run-coverage.lisp` as a child SBCL
process via [`cl-process-kit`](https://github.com/nerima-lisp/cl-process-kit),
enforcing a real, escalating (SIGTERM, then SIGKILL after a grace period)
timeout on the child instead of depending on a caller remembering to prepend
a shell `timeout`. It exits `124` if the timeout fires, matching the
`timeout(1)` convention.

```sh
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-process-kit//:$(pwd)//:" \
  sbcl --script run-ci.lisp tests              # default timeout: 120s
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-process-kit//:$(pwd)//:" \
  sbcl --script run-ci.lisp coverage 180       # explicit timeout in seconds
```

The flake wires up both dependencies automatically:

```sh
nix run .#test                                          # apps.test, no shell timeout needed
nix develop -c sbcl --script run-ci.lisp coverage 180    # coverage needs a writable working tree
nix flake check
```

There is no `nix run .#coverage`: `nix run` executes against an immutable,
read-only copy of the source under `/nix/store`, and coverage needs to write
`coverage/` next to the source it instruments. Run coverage from `nix
develop` instead, where the working tree is real.

`run-coverage.lisp` runs the suite through `cl-weave:run-all`'s native
`:coverage` support and **fails the build if coverage regresses** below the
floors set in `run-coverage.lisp` (currently 95.0% expression / 98.0%
branch — just under the 95.44%/98.21% this branch has actually reached).
Every remaining gap above that floor is confirmed non-executable by
construction or an sb-cover/SBCL instrumentation artifact; see
`CHANGELOG.md` for the line-by-line audit. The HTML report is written to
`coverage/cover-index.html`.

### Direct invocation, without the timeout wrapper

`timeout` below is an optional outer guard, not a requirement of the test
suite itself; on systems without it, run the command without the prefix.

```sh
CL_SOURCE_REGISTRY="/path/to/cl-weave//:$(pwd)//:" timeout 120s sbcl --script run-tests.lisp
CL_SOURCE_REGISTRY="/path/to/cl-weave//:$(pwd)//:" timeout 120s sbcl --script run-coverage.lisp
```

## License

MIT. See [LICENSE](LICENSE).
