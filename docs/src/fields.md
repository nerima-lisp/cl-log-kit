# Fields

Logger and call-site fields are property lists:

```lisp
(make-logger :fields '(:service "api" :attempt 1))
(log-info logger "connected" :host "db.example" :tls t)
```

## Keys and duplicates

Keys must be symbols or strings. Property lists must be finite, proper, and
contain an even number of elements — a circular or dotted list signals
`invalid-log-fields` in bounded time rather than looping or erroring
obscurely.

Field names are canonicalized case-insensitively (a symbol's `symbol-name`,
or a string as-is, downcased) before comparison. Duplicate keys after
canonicalization — for example `:PORT` and `"port"` in the same plist — signal
`invalid-log-fields`.

## Snapshotting

Records and loggers recursively **snapshot** strings, conses, arrays, hash
tables, and the explicit JSON containers (`json-object`, `json-array`)
described in [Handlers](handlers.md#json). Every public accessor
(`log-record-fields`, `logger-fields`, `json-object-members`,
`json-array-elements`, …) returns a fresh copy, so a caller that later
mutates a value it passed in — or a value it read back out — can never
change what a record or logger holds. Cyclic values signal
`invalid-log-fields` instead of recursing indefinitely; the cycle check is
Floyd's tortoise-and-hare, so it runs in bounded time even on a hostile
self-referential input.

## Condition details

Field-related conditions expose their details through readers rather than
requiring callers to parse report strings:

- `invalid-log-fields-value` / `invalid-log-fields-reason`
- `unsupported-json-value-value` / `unsupported-json-value-reason`
- `log-resource-limit-resource` / `log-resource-limit-limit` /
  `log-resource-limit-actual`

## Resource limits

Recursive snapshots enforce fixed safety limits so a hostile or accidentally
huge field value cannot exhaust memory or overflow the stack:

| Limit | Value |
| --- | --- |
| Nesting depth | 64 |
| Visited nodes | 65,536 |
| Characters per string | 1,048,576 |
| Array elements / object members | 16,384 |

Exceeding any of these signals `log-resource-limit-exceeded`. Its
`log-resource-limit-resource` reader identifies which bound failed —
`:depth`, `:nodes`, `:string-length`, `:array-elements`,
`:hash-table-entries`, or, for `log-condition`'s own output bounds,
`:condition-message-length` / `:condition-backtrace-length` (see
[Logging Conditions](conditions.md#output-bounds)). `log-resource-limit-limit`
and `log-resource-limit-actual` report the configured bound and the
observed value.
