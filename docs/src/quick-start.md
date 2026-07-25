# Quick Start

This walkthrough builds a logger, emits a few log lines, derives a scoped
child logger, and switches to JSON output. See [Installation](installation.md)
first if `cl-log-kit` is not loaded yet.

## Your first logger

```lisp
(defpackage #:my-app
  (:use #:cl #:log-kit)
  (:shadowing-import-from #:log-kit #:log))
(in-package #:my-app)

(defparameter *logger*
  (make-logger
    :name "api"
    :handler (make-instance 'text-handler)
    :level +level-info+
    :fields '(:service "orders")))

(log-info *logger* "server started" :port 8080)
;; ts=... level=INFO logger="api" msg="server started" field."port"="8080" field."service"="orders"
```

`make-logger` accepts a `:name`, a `:handler` instance, a minimum `:level`
(the default is `+level-info+`), and a base `:fields` property list shared by
every record the logger emits.

## Switching to JSON

Swap the handler — nothing else about the call sites changes:

```lisp
(defparameter *logger*
  (make-logger
    :name "api"
    :handler (make-instance 'json-handler)
    :level +level-info+
    :fields '(:service "orders")))

(log-info *logger* "server started" :port 8080)
;; {"time":...,"level":"INFO","logger":"api","message":"server started","fields":{"port":8080,"service":"orders"}}
```

See [Handlers](handlers.md) for the full `text-handler` / `json-handler`
wire formats and how to compose multiple handlers.

## Deriving a scoped logger

`logger-with` returns a new logger with additional fields; call-site fields
still override logger fields with the same canonical name:

```lisp
(defparameter *request-logger*
  (logger-with *logger* :request-id "abc123"))

(log-warn *request-logger* "slow response" :duration-ms 842)
```

See [Logger Derivation and Context](context.md) for `derive-logger`,
`logger-child`, and dynamically scoped context via `with-log-context`.

## Using a default logger

Explicit-logger and default-logger calls are separate macro families.
`log-debug` / `log-info` / `log-warn` / `log-error` / `log-fatal` always
evaluate their first argument as the logger, so `(log-info "server started"
:port 8080)` signals a `type-error` rather than falling back to
`*default-logger*`. Set `*default-logger*` once, then use the `log-default-*`
macros anywhere without threading a logger through every call site:

```lisp
(set-default-logger
  (make-logger :handler (make-instance 'text-handler)))

(log-default-error "request failed" :reason "timeout")
;; ts=... level=ERROR logger="root" msg="request failed" field."reason"="timeout"
```

`with-default-logger` scopes a different default dynamically, without
mutating the process-wide default:

```lisp
(with-default-logger (*request-logger*)
  (log-default-info "handling request"))
```

`log-default` is the generic form behind `log-default-debug` /
`log-default-info` / … — reach for it when the level is itself a variable
instead of a compile-time constant:

```lisp
(log-default level "request finished" :status status)
```

## Next steps

- [Levels](levels.md) — severities, thresholds, and level-gated evaluation.
- [Fields](fields.md) — structured field rules and resource limits.
- [Logging Conditions](conditions.md) — logging a caught Lisp condition.
- [Log Spans](spans.md) — timing an operation with `with-log-span`.
