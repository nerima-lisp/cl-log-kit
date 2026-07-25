# Changelog

The full changelog — including the line-by-line coverage audit referenced
from [Testing and Coverage](testing.md#coverage-gate) — lives in
[`CHANGELOG.md`](https://github.com/nerima-lisp/cl-log-kit/blob/main/CHANGELOG.md)
at the repository root. It is not duplicated here so the two copies cannot
drift; this page is a short pointer plus the release headlines.

## 2.0.0 — 2026-07-25

- **Breaking:** `log-debug`/`log-info`/`log-warn`/`log-error`/`log-fatal`
  always evaluate their first argument as the logger now; the old
  parity-based guess that silently fell back to `*default-logger*` for a
  message-first call is gone. Use `log-default-*` explicitly for that case.
  See [Logger Derivation and Context](context.md) and the `## [2.0.0]`
  section of `CHANGELOG.md`.
- Added: every one of the 101 exported `log-kit` symbols now has a
  docstring (81 previously had none), and the README's "Production
  readiness" section states that claim, and others, as checkable facts.

## 1.7.0 — 2026-07-25

- Coverage: closed every genuinely reachable coverage gap (bignum encoding,
  logger initarg validation, BOM/line-separator/surrogate/non-ASCII escape
  branches in both wire formats, non-keyword JSON keys, and the
  non-simple-string branch in both encoders), reaching a new best-recorded
  aggregate of 96.32% expression / 98.77% branch. Confirmed zero dead code
  via a full `paredit inspect unused-definitions` audit.
- Internal: split the shared wire-encoding primitives out of `handler.lisp`
  into their own `encoding.lisp` file.
- Changed: raised the test system's dependency floors to `cl-weave` `1.0.0`
  and `cl-json-kit` `1.0.0` (both now stable releases) and exposed the
  `paredit-cli` binary in the `nix develop` shell. See the `## [1.7.0]`
  section of `CHANGELOG.md`.

## 1.6.0 — 2026-07-25

- Performance: drove `handle-log-record` to **zero per-call allocation** on
  every benchmarked wire format and cut latency a further 1.9–4.8x (e.g.
  `text-handler` short record 1217 ns/145 B → 373 ns/0 B; float-heavy JSON
  record 2104 ns/1140 B → 1120 ns/0 B), narrowing the measured gap to
  `log4cl` from ~5.6x to ~1.4x — with no guarantee weakened (full suite and
  `nix` check unchanged). Interned keyword key names, allocation-free float
  and integer encoding, a `simple-string`/`schar` fast path, a
  printable-ASCII escape-scan fast path, and the removal of JSON's redundant
  write-time re-validation. See the `## [1.6.0]` section of `CHANGELOG.md`.

## 1.5.0 — 2026-07-25

- Added three new composition handlers, the dependency-free subset of
  Monolog-equivalent functionality: `processor-handler` (per-record
  enrichment chain), `rotating-file-handler` (clock-driven file rotation
  with retention pruning), and `buffered-handler` (hold-until-trigger,
  Monolog's FingersCrossedHandler) — see
  [Handlers → Composition and lifecycle](handlers.md#composition-and-lifecycle).
- Internal: raised the coverage gate's floors from 95.9%/98.0% to
  96.1%/98.5% to match the true aggregate this release reached (see
  [Testing and Coverage](testing.md#coverage-gate)).

## 1.4.0 — 2026-07-25

- Added `capture-log-context` / `call-with-captured-log-context` /
  `with-captured-log-context` for propagating `with-log-context` fields and
  a `with-log-span` span id across an `sb-thread:make-thread` boundary,
  which does not otherwise inherit either — see
  [Propagating context across threads](context.md#propagating-context-across-threads).
- Internal: lowered the coverage gate's expression floor from 96.0% to
  95.9% to account for the new file's unavoidable declarative-form overhead
  (see [Testing and Coverage](testing.md#coverage-gate)).

## 1.1.0 — 2026-07-24

- Fixed a false-positive `handler-lifecycle-error` when closing a
  `multi-handler` that contains a `null-handler` (or any handler that is
  always open by design).
- Internal refactors: consolidated repeated field-length bound checks,
  simplified `multi-handler`'s fan-out failure handling, extended the test
  suite's matcher vocabulary, and introduced a shared
  `with-snapshot-object` helper for cycle-safe snapshotting.

## 1.0.0

The initial public release. Established the full public surface documented
in this site: numeric levels with early filtering, immutable records and
recursive defensive snapshotting with bounded resource limits, the explicit
JSON value model, immutable logger derivation
(`derive-logger`/`logger-child`/`logger-with`) with `with-log-context`,
`text-handler`/`json-handler` with injection-safe escaping, the composition
handlers (`multi-handler`/`filter-handler`/`function-handler`/`null-handler`)
with configurable error policies, the handler lifecycle protocol, and
`condition-fields`/`log-condition`.

See the full [1.0.0 section](https://github.com/nerima-lisp/cl-log-kit/blob/main/CHANGELOG.md)
of `CHANGELOG.md` for the complete list.
