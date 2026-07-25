# Log Spans

`with-log-span` emits paired `:start` and `:end` log records around a body,
for timing an operation and correlating its two records:

```lisp
(with-log-span (*logger* "fetch-account"
                :level +level-info+
                :fields (list :account-id account-id))
  (fetch-account account-id))
```

## Record shape

Both the `:start` and `:end` record carry `:span-id` (a fresh, unique string)
and `:span-event` (`:start` or `:end`). The `:end` record additionally
carries:

- `:span-duration` — elapsed time between start and end, from the span's
  clock
- `:span-outcome` — one of:
    - `:success` — the body returned normally
    - `:error` — the body signaled an `error` condition
    - `:nonlocal-exit` — the body exited via a non-local control transfer
      other than a signaled error (e.g. `return-from`, `throw`, a restart
      invocation) — this is also what a span reports if emitting the `:end`
      record itself is interrupted before it completes

A span whose emission of the `:end` record fails does not mask an error from
the body: if the body itself already failed, that original error is what
propagates; the `:end`-record failure is only re-signaled when the body
otherwise succeeded.

## Nesting and context

Nested spans include `:parent-span-id`, pointing at the enclosing span's
`:span-id`. Every log record emitted anywhere inside a span's body — not
just the span's own `:start`/`:end` records — inherits the current
`:span-id` (and `:parent-span-id`, if nested) through the same dynamically
scoped log context that [`with-log-context`](context.md#with-log-context)
uses, so ordinary `log-info` calls inside the body are automatically
correlated with the span.

Span lifecycle keys (`:span-id`, `:parent-span-id`, `:span-event`,
`:span-duration`, `:span-outcome`) are reserved: explicit `:fields` supplied
to `with-log-span` cannot override them.

A span's id lives in the same dynamically scoped state as `with-log-context`
and is not inherited by a new thread; see
[Propagating context across threads](context.md#propagating-context-across-threads)
to carry a span into a worker thread spawned from inside its body.

## Clock and ID injection

The default duration clock is monotonic
(`(/ (get-internal-real-time) internal-time-units-per-second)`), and span IDs
default to a fresh gensym-derived string. Deterministic callers — tests, for
example — can inject their own zero-argument functions:

```lisp
(with-log-span (*logger* "fetch-account"
                :clock (lambda () 0.0d0)
                :id-source (lambda () "span-1"))
  (fetch-account account-id))
```

## Level gating

When the span's level is filtered by the logger's threshold, `with-log-span`
never evaluates the span name, fields, clock, or ID source — the body still
runs normally, just without any span records wrapped around it. This is the
same level-gated-evaluation discipline every logging macro follows; see
[Levels](levels.md#level-gated-evaluation).
