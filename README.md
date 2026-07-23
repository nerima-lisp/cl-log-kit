# cl-log-kit

A dependency-free, SBCL-only structured logging toolkit for Common Lisp.

`cl-log-kit` is loosely modeled on Go's [`log/slog`](https://pkg.go.dev/log/slog):
logging is split into a small set of **levels**, an immutable **log record**,
and a **Handler protocol** that decides how a record is actually emitted. The
protocol's single generic function, `handle-log-record`, is the *only* place
output happens -- there is no second code path that can accidentally print
the same message twice.

## Why

Two sister projects (`cl-cc`, `private-trade-fx`) each rolled their own
ad-hoc logger. `cl-cc`'s implementation had a bug where, in text mode, a log
line was printed once by its emit helper and then printed *again* by an
unrelated code path a few lines later -- every text-mode log call produced
two identical lines. `cl-log-kit` prevents that entire class of bug
structurally: a `handler` is a CLOS object whose `handle-log-record` method
is the single place it is allowed to write output, so "print the record" can
only ever happen in one place per handler.

## Installation

### Nix flake

```
nix build github:nerima-lisp/cl-log-kit
```

Or add it as a flake input and pull in the `cl-log-kit` package/devShell.

### Quicklisp-local / ASDF

Clone this repository somewhere ASDF can find it (e.g. under
`~/quicklisp/local-projects/` or anywhere on your `CL_SOURCE_REGISTRY`), then:

```lisp
(asdf:load-system "cl-log-kit")
```

## Usage

```lisp
(defpackage #:my-app
  (:use #:cl #:log-kit))
(in-package #:my-app)

;; A logger bundles a handler, a minimum level, and bound context fields.
(defparameter *logger*
  (make-logger :name "my-app"
               :handler (make-instance 'json-handler)
               :level +level-info+))

(log-info *logger* "server started" :port 8080)
;; => {"timestamp":...,"level":"INFO","message":"server started","logger":"my-app","port":8080}

;; logger-with returns a *new* logger with extra bound fields; it never
;; mutates the logger it was called on.
(defparameter *request-logger* (logger-with *logger* :request-id "abc123"))
(log-warn *request-logger* "slow response" :duration-ms 842)

;; The convenience functions also work against *default-logger* when no
;; logger is passed explicitly.
(set-default-logger (make-logger :handler (make-instance 'text-handler)))
(log-error "unhandled condition" :reason "timeout")
;; => [ERROR] unhandled condition reason=timeout
```

### Levels

```lisp
+level-debug+ < +level-info+ < +level-warn+ < +level-error+ < +level-fatal+
```

Records below a logger's configured `level` are filtered out before the
handler is ever invoked -- `handle-log-record` is never called for them.

### Handlers

- `text-handler` -- one human-readable line per record:
  `[LEVEL] message key=value key=value`
- `json-handler` -- one JSON object per line, with `timestamp`, `level`,
  `message`, `logger`, and any bound/call-site fields, with correct escaping
  of `"`, `\`, newlines, tabs, and other control characters.

Both ship with a `:stream` initarg (defaulting to `*standard-output*`), which
also makes them trivial to test by pointing at a string stream.

### Deterministic testing

`logger`'s `:clock` initarg (default `#'get-universal-time`) is the sole
source of `log-record-timestamp`. Inject a fixed-value function in tests to
get fully deterministic timestamps:

```lisp
(make-logger :clock (lambda () 0))
```

## Design intent

See the `log-kit` package for the full exported API. The core idea, borrowed
from Go's `log/slog`, is to separate "what happened" (a `log-record`) from
"how it gets written" (a `handler`), so alternative output formats or
destinations can be added by implementing a single generic function without
touching logger or call-site code.

## License

MIT. See [LICENSE](LICENSE).
