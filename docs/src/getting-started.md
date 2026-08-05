# Getting Started

!!! info "Prerequisites"

    `cl-log-kit` targets [SBCL](https://www.sbcl.org/) and requires ASDF
    3.3.1 or newer (a modern SBCL already bundles a recent-enough ASDF). The
    shipped `cl-log-kit` system also depends on three nerima-lisp toolkit
    packages — `cl-date-kit`, `cl-concurrent-kit`, and `cl-host-kit` — loaded
    at runtime; see [Compatibility](reference/compatibility.md) for what each
    is used for.

## Installing

Pick the path that matches how you use the library.

=== "ASDF (manual clone)"

    Clone the repository somewhere ASDF can find it, then load the system:

    ```sh
    git clone https://github.com/nerima-lisp/cl-log-kit.git
    ```

    ```lisp
    (asdf:load-system "cl-log-kit")
    ```

    ASDF finds the system if the clone is on `CL_SOURCE_REGISTRY` or under a
    directory ASDF already searches (e.g. `~/common-lisp/` or
    `~/.local/share/common-lisp/source/`).

=== "Nix flake"

    Build the packaged ASDF system directly:

    ```sh
    nix build github:nerima-lisp/cl-log-kit
    ```

    The build output's root is the ASDF source tree — `result/cl-log-kit.asd`
    sits at the top level. Reference `cl-log-kit` from your own flake as an
    input and append its store path to `CL_SOURCE_REGISTRY`:

    ```nix
    CL_SOURCE_REGISTRY = "${cl-log-kit}//:${CL_SOURCE_REGISTRY:-}";
    ```

    or, from the command line:

    ```sh
    CL_SOURCE_REGISTRY="$(nix build github:nerima-lisp/cl-log-kit --print-out-paths --no-link)//:"
    ```

=== "Local checkout (contributors)"

    Clone the repository, then work inside the reproducible dev shell, which
    wires up the test-only dependencies automatically:

    ```sh
    git clone https://github.com/nerima-lisp/cl-log-kit.git
    cd cl-log-kit
    nix develop                 # SBCL + CL_SOURCE_REGISTRY for cl-weave
                                 # and cl-json-kit
    nix run .#test               # run the test suite with a real timeout
    nix flake check               # every CI entrypoint
    ```

    `run-tests.lisp` and `run-coverage.lisp` also work
    without Nix — see [Development](project/development.md) for the direct
    `CL_SOURCE_REGISTRY` invocation. `cl-log-kit/test` requires `cl-weave`
    1.3.0 or newer and `cl-json-kit` 1.2.0 or newer; the flake pins both, so
    only a hand-managed `CL_SOURCE_REGISTRY` can point at an older checkout.

## Runtime Support

`cl-log-kit` is developed and tested against SBCL, and its runtime
dependencies (`cl-date-kit`, `cl-concurrent-kit`, `cl-host-kit`) are
themselves SBCL-only, so it should load cleanly on any modern ASDF 3.3.1+
SBCL setup; SBCL is the only implementation the test suite and CI pipeline
exercise. See [Compatibility](reference/compatibility.md) for the platforms
the flake builds and the stability promise attached to the exported surface.

## Package and Naming

Load the system, then `:use` the `log-kit` package:

```lisp
(defpackage #:my-app
  (:use #:cl #:log-kit)
  (:shadowing-import-from #:log-kit #:log))
(in-package #:my-app)
```

`log-kit` shadows the common-lisp `log` symbol for its own `log` macro, the
arbitrary-level general form behind `log-debug`/`log-info`/etc. That symbol
is internal, so `:use`-ing `log-kit` alone leaves `cl:log` (the logarithm)
accessible; the `:shadowing-import-from` line above is what makes `log-kit`'s
macro available under that name instead, and can be dropped if you only use
the fixed-level macros.

## Your first logger

```lisp
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

See [Handlers](guide/handlers.md) for the full `text-handler` /
`json-handler` wire formats and how to compose multiple handlers.

## Deriving a scoped logger

`logger-with` returns a new logger with additional fields; call-site fields
still override logger fields with the same canonical name:

```lisp
(defparameter *request-logger*
  (logger-with *logger* :request-id "abc123"))

(log-warn *request-logger* "slow response" :duration-ms 842)
```

See [Logger Derivation and Context](guide/context.md) for `derive-logger`,
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

- [Levels](guide/levels.md) — severities, thresholds, and level-gated evaluation.
- [Fields](guide/fields.md) — structured field rules and resource limits.
- [Logging Conditions](reference/conditions.md) — logging a caught Lisp condition.
- [Log Spans](guide/spans.md) — timing an operation with `with-log-span`.
