# API Reference

Every symbol exported from the `log-kit` package (see
[`src/package.lisp`](https://github.com/nerima-lisp/cl-log-kit/blob/main/src/package.lisp)),
grouped by area. `log-kit` shadows the common-lisp `log` symbol — see
[Installation](installation.md#package-and-naming).

## Levels

See [Levels](levels.md) for the full discussion.

| Symbol | Kind | Description |
| --- | --- | --- |
| `+level-debug+` | constant | `0` |
| `+level-info+` | constant | `10` (default logger threshold) |
| `+level-warn+` | constant | `20` |
| `+level-error+` | constant | `30` |
| `+level-fatal+` | constant | `40` |
| `level-name` | function | canonical name for a level integer |
| `level<` | function | true when level `a` ranks strictly below `b` |
| `level<=` | function | true when level `a` ranks at or below `b` |
| `log-enabled-p` | function | true when a level passes a logger's threshold |

## Errors and Conditions

See [Fields](fields.md#resource-limits) for the resource-limit table.

| Symbol | Kind | Description |
| --- | --- | --- |
| `log-kit-error` | condition | base condition for every error `cl-log-kit` signals |
| `invalid-log-fields` | condition | malformed or duplicate field data |
| `invalid-log-fields-value` | reader | the offending value |
| `invalid-log-fields-reason` | reader | human-readable reason string |
| `unsupported-json-value` | condition | a value has no supported JSON encoding |
| `unsupported-json-value-value` | reader | the offending value |
| `unsupported-json-value-reason` | reader | human-readable reason string |
| `log-resource-limit-exceeded` | condition | a fixed safety bound was exceeded |
| `log-resource-limit-resource` | reader | which bound failed (`:depth`, `:nodes`, `:string-length`, `:array-elements`, `:hash-table-entries`, `:condition-message-length`, `:condition-backtrace-length`) |
| `log-resource-limit-limit` | reader | the configured bound |
| `log-resource-limit-actual` | reader | the observed value |
| `handler-lifecycle-error` | condition | an operation was attempted on a handler in the wrong lifecycle state |
| `handler-lifecycle-error-handler` | reader | the target handler |
| `handler-lifecycle-error-operation` | reader | `:handle`, `:flush`, or `:close` |
| `handler-lifecycle-error-state` | reader | the handler's lifecycle state at the time |

## JSON Value Model

See [Handlers → JSON](handlers.md#json) for the encoding table.

| Symbol | Kind | Description |
| --- | --- | --- |
| `+json-null+` | constant | explicit JSON `null` marker |
| `+json-false+` | constant | explicit JSON `false` marker |
| `json-null-p` | function | true for `+json-null+` |
| `json-false-p` | function | true for `+json-false+` |
| `json-object` | function | build an explicit JSON object from an alist |
| `json-object-p` | function | true for a `json-object` value |
| `json-object-members` | function | defensive snapshot of a `json-object`'s alist |
| `json-array` | function | build an explicit JSON array from a list or vector |
| `json-array-p` | function | true for a `json-array` value |
| `json-array-elements` | function | defensive snapshot of a `json-array`'s vector |

## Fields

See [Fields](fields.md).

| Symbol | Kind | Description |
| --- | --- | --- |
| `plist-to-alist` | function | validate and snapshot a field plist into a canonical alist |

## Log Records

See [Records and Extension](extension.md#log-record).

| Symbol | Kind | Description |
| --- | --- | --- |
| `log-record` | struct type | an immutable log-event snapshot |
| `make-log-record` | function | build a `log-record` directly |
| `log-record-level` | function | the record's level |
| `log-record-message` | function | the record's message (defensive copy) |
| `log-record-timestamp` | function | the record's timestamp |
| `log-record-fields` | function | the record's fields (defensive copy) |
| `log-record-logger-name` | function | the emitting logger's name (defensive copy) |

## Handler Protocol

See [Records and Extension → Implementing a new handler](extension.md#implementing-a-new-handler).

| Symbol | Kind | Description |
| --- | --- | --- |
| `handler` | class | base class every handler subclasses |
| `handle-log-record` | generic function | emit a record exactly once |
| `flush-handler` | generic function | flush buffered output |
| `close-handler` | generic function | close the handler and its stream, if owned |
| `handler-open-p` | generic function | whether the handler currently accepts operations |
| `with-handler` | macro | bind and close a handler on every exit |

## Built-in Handlers

See [Handlers](handlers.md) for wire formats and stream semantics.

| Symbol | Kind | Description |
| --- | --- | --- |
| `text-handler` | class | key=value text output |
| `json-handler` | class | one JSON object per line |
| `make-text-handler` | function | `text-handler` constructor (`:stream`, `:auto-flush`, `:owns-stream`) |
| `make-json-handler` | function | `json-handler` constructor (`:stream`, `:auto-flush`, `:owns-stream`) |

## Composition Handlers

See [Handlers → Composition and lifecycle](handlers.md#composition-and-lifecycle).

| Symbol | Kind | Description |
| --- | --- | --- |
| `multi-handler` | class | fan out to multiple child handlers with an error policy |
| `make-multi-handler` | function | `multi-handler` constructor |
| `filter-handler` | class | forward records accepted by a predicate |
| `make-filter-handler` | function | `filter-handler` constructor |
| `function-handler` | class | adapt plain functions as a handler |
| `make-function-handler` | function | `function-handler` constructor |
| `null-handler` | class | discard every record |
| `make-null-handler` | function | `null-handler` constructor |
| `processor-handler` | class | run a processor chain over each record before forwarding it |
| `make-processor-handler` | function | `processor-handler` constructor |
| `rotating-file-handler` | class | write to a file that rotates when an injectable clock's bucket changes |
| `make-rotating-file-handler` | function | `rotating-file-handler` constructor |
| `buffered-handler` | class | hold records back until a trigger-level record arrives, then release them all |
| `make-buffered-handler` | function | `buffered-handler` constructor |

## Loggers

See [Quick Start](quick-start.md) and
[Logger Derivation and Context](context.md).

| Symbol | Kind | Description |
| --- | --- | --- |
| `logger` | class | immutable logging configuration and contextual fields |
| `make-logger` | function | `logger` constructor (`:name`, `:handler`, `:level`, `:fields`, `:clock`) |
| `logger-with` | function | derive a logger with merged fields |
| `derive-logger` | function | derive a logger, optionally replacing name/handler/level/fields/clock |
| `logger-child` | function | derive a logger with a dot-separated child name |
| `logger-name` | function | the logger's name (defensive copy) |
| `logger-level` | function | the logger's minimum level |
| `logger-fields` | function | the logger's fields (defensive copy) |
| `logger-clock` | function | the logger's zero-argument timestamp function |
| `logger-handler` | function | the logger's handler |
| `flush-logger` | function | flush the logger's handler and return the logger |

## Default Logger and Context

See [Quick Start → Using a default logger](quick-start.md#using-a-default-logger)
and [Logger Derivation and Context → `with-log-context`](context.md#with-log-context).

| Symbol | Kind | Description |
| --- | --- | --- |
| `*default-logger*` | dynamic variable | the logger `log-default-*` macros use |
| `set-default-logger` | function | replace `*default-logger*` process-wide |
| `with-default-logger` | macro | dynamically scope a different default logger |
| `with-log-context` | macro | dynamically scope additional fields across a call stack |

## Thread Context Propagation

See [Logger Derivation and Context → Propagating context across threads](context.md#propagating-context-across-threads).

| Symbol | Kind | Description |
| --- | --- | --- |
| `log-context-snapshot` | struct type | an opaque snapshot of the active context fields and span id |
| `log-context-snapshot-p` | function | true for a `log-context-snapshot` value |
| `capture-log-context` | function | snapshot the calling thread's active context and span id |
| `call-with-captured-log-context` | function | call a thunk with a snapshot restored as the active state |
| `with-captured-log-context` | macro | run a body with a snapshot restored as the active state |

## Logging Macros

See [Quick Start](quick-start.md) and [Levels → Level-gated evaluation](levels.md#level-gated-evaluation).

| Symbol | Kind | Description |
| --- | --- | --- |
| `emit-log` | function | low-level: check the level, then build and emit a record, or return `nil` |
| `log-debug` / `log-info` / `log-warn` / `log-error` / `log-fatal` | macro | explicit-logger logging at each level |
| `log-default` | macro | `(log-default level message &rest fields)` — logging at an arbitrary level against `*default-logger*` |
| `log-default-debug` / `log-default-info` / `log-default-warn` / `log-default-error` / `log-default-fatal` | macro | logging at each fixed level against `*default-logger*` |

## Logging Conditions

See [Logging Conditions](conditions.md).

| Symbol | Kind | Description |
| --- | --- | --- |
| `condition-fields` | function | turn a condition into `:condition-type` / `:condition-message` / `:backtrace` fields |
| `log-condition` | macro | log a condition on a logger at a level |

## Log Spans

See [Log Spans](spans.md).

| Symbol | Kind | Description |
| --- | --- | --- |
| `with-log-span` | macro | emit paired `:start` / `:end` records around a body |
