# Changelog

The full changelog lives in
[`CHANGELOG.md`](https://github.com/nerima-lisp/cl-log-kit/blob/main/CHANGELOG.md)
at the repository root. It is not duplicated here so the two copies cannot
drift; this page is a short pointer plus the release headlines.

## 1.0.0 — 2026-07-26

The first stable release, and a commitment that the 101 exported `log-kit`
symbols are a stable surface: anything that changes their shape or behavior
from here on gets a major version and a documented migration path.

What 1.0.0 establishes:

- **Records and handlers, separated.** Immutable [records](fields.md)
  flow to [handlers](handlers.md) through one `handle-log-record` method,
  so there is no second code path that could emit a record twice.
- **[Levels](levels.md) with early filtering.** Every logging macro tests
  the level before evaluating its message and field forms, so a filtered
  call costs a single integer comparison.
- **Deep, bounded, cycle-checked [snapshotting](fields.md#snapshotting).**
  A record cannot observe a later mutation, a cyclic value is rejected
  rather than followed, and depth, node count, string length, and
  collection size are all capped with structured conditions.
- **Injection-safe [wire formats](handlers.md).** `text-handler` escapes
  control, bidirectional, and invisible characters so user data cannot
  forge a log line; `json-handler` emits strict RFC 8259 and validates the
  whole record before writing a byte.
- **[Composition handlers](handlers.md#composition-and-lifecycle)** —
  multi, filter, function, null, processor, rotating-file, and buffered —
  over a thread-safe lifecycle that guarantees close-at-most-once under
  concurrent and re-entrant callers.
- **[Logger derivation and context](context.md)**, including
  [cross-thread propagation](context.md#propagating-context-across-threads),
  [spans](spans.md), and [condition logging](conditions.md) with bounded
  report and backtrace output.
- **Zero per-call allocation** in `handle-log-record` on every benchmarked
  wire format, and a coverage-gated, timeout-enforced CI pipeline — see
  [Testing and Coverage](testing.md).
