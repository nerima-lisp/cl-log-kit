# cl-log-kit

`cl-log-kit` is a dependency-free, SBCL-only structured logging toolkit for
Common Lisp, inspired by Go's `log/slog`. It separates immutable log records
from handlers that serialize them: every built-in handler emits a record
through exactly one `handle-log-record` method, so there is no way to end up
with duplicate output paths.

!!! tip "New to cl-log-kit?"

    Load it, build a logger, and emit your first structured log line in under
    a minute:

    ```lisp
    (asdf:load-system "cl-log-kit")
    ```

    Continue with [Installation](installation.md) → [Quick Start](quick-start.md)
    → [Levels](levels.md) and [Fields](fields.md).

## Explore the docs

<div class="grid cards" markdown>

-   :material-rocket-launch:{ .lg .middle } &nbsp; **Getting Started**

    ---

    Load the system with ASDF or Nix, and build your first logger and log
    line.

    [:octicons-arrow-right-24: Installation](installation.md) ·
    [Quick Start](quick-start.md)

-   :material-format-list-bulleted:{ .lg .middle } &nbsp; **Core Concepts**

    ---

    Severity levels, structured fields, and how loggers derive scoped
    children with `logger-with`, `derive-logger`, and `with-log-context`.

    [:octicons-arrow-right-24: Levels](levels.md) ·
    [Fields](fields.md) ·
    [Logger Derivation and Context](context.md)

-   :material-tray-arrow-up:{ .lg .middle } &nbsp; **Handlers**

    ---

    Text and JSON output, composition with `multi-handler` and
    `filter-handler`, file rotation and trigger-based buffering, and the
    handler lifecycle protocol.

    [:octicons-arrow-right-24: Handlers](handlers.md)

-   :material-timeline-clock-outline:{ .lg .middle } &nbsp; **Conditions and Spans**

    ---

    Turn Lisp conditions into structured fields, and time an operation with
    paired start/end log records.

    [:octicons-arrow-right-24: Logging Conditions](conditions.md) ·
    [Log Spans](spans.md)

</div>

## Status

Version 2.0.0. `cl-log-kit` is a small, stable surface — see the
[API Reference](api-reference.md) for the full list of exported symbols. The
capability list below is the intended public surface, validated by the test
suite documented in [Testing and Coverage](testing.md):

- `make-logger` / `logger-with` / `derive-logger` / `logger-child` for
  building and deriving structured loggers
- explicit-logger logging macros (`log-debug`, `log-info`, `log-warn`,
  `log-error`, `log-fatal`), which always take the logger as their first
  argument, and their `log-default-*` counterparts against `*default-logger*`
- `with-default-logger` for a dynamically scoped default logger
- `with-log-context` for dynamically scoped fields shared across a call
  stack, plus `capture-log-context` / `with-captured-log-context` for
  carrying that context into a new thread
- five built-in severity levels (`DEBUG` < `INFO` < `WARN` < `ERROR` <
  `FATAL`) plus arbitrary integer custom levels
- level-gated macros that skip message/field evaluation, clock access, and
  handler work entirely when a call is filtered
- property-list fields with case-insensitive canonical keys and strict
  duplicate-key rejection
- recursive, cycle-safe snapshotting of strings, conses, arrays, hash
  tables, and explicit JSON containers, with fixed resource limits
- `text-handler` and `json-handler` built-in output handlers, both
  injection-safe against control characters, DEL, and bidi/invisible
  spoofing controls
- an explicit JSON value model (`json-object`, `json-array`, `+json-null+`,
  `+json-false+`) so field encoding is never guessed from Lisp types
- `multi-handler`, `filter-handler`, `function-handler`, and `null-handler`
  for composing and adapting handlers
- `processor-handler` for per-record enrichment, `rotating-file-handler` for
  clock-driven file rotation with retention pruning, and `buffered-handler`
  for holding records back until a trigger-level record arrives
- an extensible handler lifecycle protocol (`handler-open-p`,
  `flush-handler`, `close-handler`, `with-handler`, `flush-logger`) with
  atomic handle/flush/close admission
- `condition-fields` / `log-condition` for turning Lisp conditions into
  structured `:condition-type` / `:condition-message` / `:backtrace` fields
- `with-log-span` for paired `:start` / `:end` records with duration,
  outcome, and parent/child span correlation
- a `handler` extension protocol for new destinations and encodings

## Guide Map

- [Installation](installation.md) — loading `cl-log-kit` with ASDF or Nix.
- [Quick Start](quick-start.md) — a first logger, a first log line, JSON
  output.
- [Levels](levels.md) — the five built-in severities, custom levels, and
  level-gated evaluation.
- [Fields](fields.md) — property-list fields, canonicalization, snapshotting,
  and resource limits.
- [Logger Derivation and Context](context.md) — `logger-with`,
  `derive-logger`, `logger-child`, and `with-log-context` precedence rules.
- [Handlers](handlers.md) — `text-handler`, `json-handler`, composition, and
  the lifecycle protocol.
- [Logging Conditions](conditions.md) — `condition-fields` and
  `log-condition`.
- [Log Spans](spans.md) — `with-log-span` timing and correlation.
- [Records and Extension](extension.md) — `log-record`, implementing new
  handlers, and injecting a deterministic clock.
- [API Reference](api-reference.md) — every exported symbol, grouped by area.
- [Testing and Coverage](testing.md) — `run-ci.lisp`, coverage floors, and the
  Nix-driven test workflow.

## Nix Workflow

The [flake.nix](https://github.com/nerima-lisp/cl-log-kit/blob/main/flake.nix)
at the repository root packages `cl-log-kit` as a Nix flake:

- `nix develop` — a devShell with SBCL and the test-only dependencies
  (`cl-weave`, `cl-process-kit`, `cl-json-kit`) wired into
  `CL_SOURCE_REGISTRY`.
- `nix build` — builds the `cl-log-kit` ASDF system as a Nix package.
- `nix run .#test` — runs the test suite through `run-ci.lisp`, with a real
  escalating timeout.
- `nix flake check` — the test suite as a reproducible derivation.
- `nix build .#docs` — builds this documentation site with MkDocs (Material)
  in `--strict` mode, so broken links fail the build.

## License

MIT. See [LICENSE](https://github.com/nerima-lisp/cl-log-kit/blob/main/LICENSE).
