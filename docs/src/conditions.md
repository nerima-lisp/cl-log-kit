# Logging Conditions

`log-condition` turns a caught Lisp condition into structured fields and
emits it as a log record — the field-building work `condition-fields`
performs, plus level gating and merging with any explicit fields:

```lisp
(handler-case
    (perform-request)
  (error (condition)
    (log-condition *logger* +level-error+ condition
      :message "request failed"
      :fields (list :request-id request-id)
      :capture-backtrace t)))
```

Like every other logging macro, `log-condition` evaluates `condition`,
`:fields`, and `:backtrace` only when `level` passes `logger`'s filter —
a filtered call never renders a condition report or captures a backtrace.

## Reserved keys

`log-condition` always emits `:condition-type` and `:condition-message`,
and `:backtrace` when `:capture-backtrace t` or an explicit `:backtrace` is
supplied. These three keys are reserved: explicit `:fields` are merged using
the normal [event-field precedence](context.md#field-precedence), but a
`:fields` entry for `:condition-type`, `:condition-message`, or `:backtrace`
cannot override the value `log-condition` derived.

## Safe by default

By default, condition logging does **not** execute the condition's own
`:report` method — instead it emits a safe, type-based message such as
`<condition my-error>`. This matters because a condition's report method is
arbitrary user code that could be slow, throw, or produce unbounded output.

Pass `:render-report t` to opt in to executing the report method once. The
captured report output is bounded (see below), but the report method's own
CPU time and wall-clock execution time are **not** bounded — only use
`:render-report t` for conditions whose report methods you trust.

If report rendering fails (the report method itself signals), `log-condition`
falls back to a safe placeholder message rather than propagating the
failure.

## Output bounds

Rendered messages and backtraces are captured through a bounded output
stream that aborts the moment it would exceed its limit, so a hostile or
enormous condition can never over-allocate:

| Field | Default limit | Override |
| --- | --- | --- |
| Condition message | 2,048 characters | `:message-limit` |
| Backtrace | 8,192 characters | `:backtrace-limit` |

Both limits are themselves capped by the global
[field string-length limit](fields.md#resource-limits) (1,048,576
characters) — requesting a limit above that signals
`log-resource-limit-exceeded` instead of silently clamping.

## `condition-fields`

The lower-level function `log-condition` builds on. Use it directly when you
need the field plist without emitting a log record:

```lisp
(condition-fields condition
  :backtrace nil                ; explicit backtrace string/object, or nil to capture
  :capture-backtrace nil        ; capture the current backtrace when true
  :render-report nil            ; execute the condition's own report method
  :message-limit 2048
  :backtrace-limit 8192)
;; => (:condition-type "my-error" :condition-message "<condition my-error>")
```
