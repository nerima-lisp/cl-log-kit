# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

### Changed

### Fixed

## [1.0.0] - 2026-07-26

The first stable release.

`cl-log-kit` is a dependency-free, SBCL-only structured logging toolkit
modelled on Go's `log/slog`: immutable log *records* are separated from
*handlers* that serialize them, and `handle-log-record` is the single method
through which a record reaches output. Tagging 1.0.0 is a commitment that
the 101 exported symbols this entry describes are a stable surface —
anything that changes their shape or behavior from here on gets a major
version and a documented migration path.

### Added

#### Levels and filtering

- Integer level ranks `+level-debug+` (0), `+level-info+` (10),
  `+level-warn+` (20), `+level-error+` (30), and `+level-fatal+` (40), with
  `level-name`, `level<`, and `level<=`. Custom integer levels are accepted
  and render numerically when they match no standard rank.
- `log`, `log-debug`, `log-info`, `log-warn`, `log-error`, and `log-fatal`
  take an explicit logger as their first argument; `log-default`,
  `log-default-debug`, and its siblings go through `*default-logger*`. The
  two families are deliberately distinct spellings rather than one macro
  that guesses which one you meant from its argument shape.
- Every logging macro tests the level *before* evaluating its message and
  field forms, so a filtered call performs no record construction, field
  allocation, clock read, or handler work. The logger expression itself is
  evaluated exactly once.
- `log-enabled-p` exposes the same predicate the macros use, and `emit-log`
  is the ordinary-function entry point, returning the emitted `log-record`
  or `nil` when the level is filtered. Being a function, it evaluates its
  arguments unconditionally — which is exactly why the macros exist.
- `*default-logger*`, `set-default-logger` (process-wide), and
  `with-default-logger` (dynamically scoped).

#### Records and defensive snapshotting

- `log-record`: an immutable value carrying a level, message, timestamp,
  field alist, and logger name. `make-log-record` builds one directly;
  `log-record-level`, `-message`, `-timestamp`, `-fields`, and
  `-logger-name` read it back.
- Construction deep-copies strings, conses, arrays, hash tables, and the
  explicit JSON containers, and every public accessor returns a *fresh*
  copy. A caller that mutates a value it passed in — or one it read back
  out — cannot change what a record or logger holds.
- Cyclic values signal `invalid-log-fields` rather than recursing forever:
  the snapshot walk marks each container it is currently copying in an `eq`
  table. A value reachable twice without being circular is a DAG and
  snapshots normally.
- The list-shape checks that run *before* the walk (plist properness, JSON
  object member and array element lists) use Floyd's tortoise-and-hare, so a
  circular list is rejected in bounded time without being traversed.
- Fixed resource limits — nesting depth 64, 65,536 visited nodes, 1,048,576
  characters per string, 16,384 elements per collection — each signalling
  `log-resource-limit-exceeded` with `log-resource-limit-resource`,
  `-limit`, and `-actual` readers. A logging call can never become the
  vector for an unbounded-memory or non-terminating bug, even on
  attacker-influenced field values.
- A list's *length* is charged to the collection-element bound and the node
  budget, not to nesting depth: only genuine nesting descends a level. A
  flat 100-element list field behaves like the equivalent vector or JSON
  array rather than being rejected as "100 levels deep."

#### Fields

- Logger and call-site fields are property lists with symbol or string keys.
  Keys are canonicalized case-insensitively, so `:PORT` and `"port"` in the
  same plist collide and signal `invalid-log-fields`.
- `plist-to-alist` is the public spelling of that validation and
  canonicalization.
- Precedence is fixed and documented: event (call-site) fields override
  dynamic context fields, which override logger fields.

#### The explicit JSON value model

- `json-object` and `json-array` wrappers for nested structure, plus
  `+json-null+` and `+json-false+` sentinels distinct from Lisp `nil`, with
  `json-object-p`, `json-array-p`, `json-null-p`, `json-false-p`,
  `json-object-members`, and `json-array-elements`.
- Nesting is explicit by design: an arbitrary list or vector is never
  silently inferred to be a JSON array. Unsupported objects and non-finite
  floats signal `unsupported-json-value` instead of being stringified.

#### Loggers, derivation, and context

- `logger` and `make-logger`, with `:name`, `:handler`, `:level`, `:fields`,
  and an injectable zero-argument `:clock` (Unix seconds by default) for
  deterministic tests.
- `derive-logger` (replace any subset of slots, merging fields),
  `logger-child` (dot-separated child names, shape-validated), and
  `logger-with` (the fields-only shortcut). All three return a new logger;
  none mutates.
- `with-log-context` attaches dynamically scoped fields to every log call
  made anywhere in its body, including from functions further down the
  stack.
- `flush-logger` flushes a logger's handler and returns the logger.

#### Log spans

- `with-log-span` emits paired `:start` and `:end` records around a body,
  with `:span-id`, `:span-event`, `:span-duration`, a `:span-outcome` of
  `:success`/`:error`/`:nonlocal-exit`, and `:parent-span-id` for nested
  spans. Records logged inside the body inherit the span id through the
  logging context.
- Span lifecycle keys are reserved: a caller's own `:fields` cannot
  overwrite them, whether spelled as a keyword or as a string.
- Default span ids are handed out by an atomic counter, so they stay
  distinct across concurrent threads. `:clock` and `:id-source` are
  injectable for deterministic tests, and neither they nor the span's name
  and fields are evaluated when the span's level is filtered.

#### Cross-thread context propagation

- `sb-thread:make-thread` does not inherit dynamic bindings, so a worker
  thread starts with no logging context. `capture-log-context`,
  `with-captured-log-context`, `call-with-captured-log-context`, and the
  opaque `log-context-snapshot` type move the active context fields and span
  id across that boundary explicitly.

#### Stream handlers

- `text-handler` writes one physical line per record as
  `ts=… level=… logger="…" msg="…" field."k"="v"`. Newlines, returns, tabs,
  control characters, DEL, U+2028/U+2029, and bidirectional or invisible
  spoofing controls are escaped in messages, keys, and values, so user data
  cannot inject or visually disguise another log line. Arbitrary objects
  render as the placeholder `#<object>` without invoking a user-defined
  printer.
- `json-handler` writes one strict RFC 8259 object per line, with `time`,
  `level`, `logger`, `message`, and `fields` as the reserved top-level keys.
  User fields always live inside `fields` and never at the top level. The
  whole record is validated before a single byte is written, so a partial
  object can never reach the stream.
- `make-text-handler` / `make-json-handler`, and both classes, accept
  `:stream`, `:auto-flush`, and `:owns-stream`.
- Handlers sharing one stream share a single reentrant write lock, so their
  lines cannot interleave; each write and its automatic flush execute as one
  operation. `close-handler` is idempotent, closes the stream only under
  `:owns-stream t`, and defers physical close if an owned stream is closed
  reentrantly from a stream callback during a write, rather than
  deadlocking against itself.

#### Composition handlers

- `make-multi-handler` fans a record out to each child in order, under an
  `:error-policy` of `:signal` (the default: stop and re-signal),
  `:continue`, or `:callback`. `close-handler` is the deliberate exception:
  every child is given a chance to close before the first error is
  re-signaled, and a failed close can be retried.
- `make-filter-handler` (predicate gate), `make-function-handler` (adapt a
  closure, with optional flush and close callbacks), and
  `make-null-handler`.
- `make-processor-handler` runs a chain of enrichment functions over every
  record before forwarding it. Contributed fields merge *under* whatever the
  record already carried, so a processor can enrich but never clobber real
  call-site or logger data; between processors, later wins.
- `make-rotating-file-handler` derives its filename from a base pathname and
  a zero-argument clock (today's local date by default), opens a fresh file
  when the clock's value changes, and prunes rotated files beyond an
  optional `:max-files` retention count, oldest first. Base pathnames with
  and without a file type both rotate and prune.
- `make-buffered-handler` holds records back until one at or above
  `:trigger-level` arrives, then releases the whole held-back run in order.
  `:buffer-size` bounds how many are held while waiting (oldest dropped
  first) and `:stop-buffering` controls whether it stays activated
  afterwards. Flush and close never force an unreleased buffer out.
- Composition handlers admit each handle or flush operation atomically. An
  operation admitted before close finishes before close reaches any child;
  once close starts, later operations signal `handler-lifecycle-error`
  before invoking a predicate, child, or callback. A callback that tries to
  synchronously close the handler it is running inside gets the same
  condition instead of a deadlock.
- `handler-open-p` is an extensible generic function; `with-handler` closes
  its handler on every exit.

#### Condition logging

- `condition-fields` renders a condition into `:condition-type` and
  `:condition-message` fields, with an optional supplied or captured
  `:backtrace`. `log-condition` emits them and, like the other logging
  macros, evaluates nothing when the level is filtered.
- By default no user-defined `report` method is executed — a safe
  type-derived message is emitted instead. `:render-report t` opts in to
  running it exactly once, under a bounded output stream that unwinds the
  report rather than over-allocating. Messages default to 2,048 characters
  and backtraces to 8,192; `:message-limit` and `:backtrace-limit` override
  both.
- The condition keys are reserved and cannot be replaced through `:fields`.

#### Errors

- A single `log-kit-error` root with `invalid-log-fields`,
  `unsupported-json-value`, `log-resource-limit-exceeded`, and
  `handler-lifecycle-error` beneath it. Every one exposes its details
  through readers, so no caller has to parse a report string.

#### Extension

- Subclass `handler` and specialize `handle-log-record`; stateful handlers
  should also specialize `handler-open-p`, `flush-handler`, and
  `close-handler`. Every exported symbol carries a docstring, so
  `documentation` answers at the REPL for the whole public surface.

### Performance

- `handle-log-record` allocates **zero bytes per call** on every benchmarked
  wire format and payload. Figures from one `benchmark/run.lisp` run on
  SBCL 2.6.0 / aarch64-darwin (minimum wall-clock time and bytes consed per
  call over several full-GC'd repetitions):

  | Benchmark | ns/call | bytes/call |
  | --- | --- | --- |
  | `text-handler`, ASCII message + 3 fields | 392 | 0 |
  | `json-handler`, ASCII message + 3 fields | 832 | 0 |
  | `text-handler`, 256-char field value | 686 | 0 |
  | `json-handler`, 256-char field value | 1787 | 0 |
  | `json-handler`, double-float-heavy fields | 1227 | 0 |

  The timings are machine-specific and will move; the `0 bytes/call` column
  is the property the suite actually asserts, in
  `t/performance-test.lisp`'s allocation-bound specs.
- What buys that: interned downcased keyword key names behind a
  copy-on-write cache, allocation-free base-10 integer and float encoding, a
  `simple-string`/`schar` fast path in both encoders, a printable-ASCII
  fast path in the escape scan, stack-allocated writer closures, a
  conditional rather than unconditional waitqueue broadcast, and the removal
  of JSON's redundant write-time re-validation.
- `benchmark/competitors.lisp` runs the same methodology against
  [`log4cl`](https://github.com/sharplispers/log4cl), both writing an
  equivalent message and fields to a discarding stream. On the same run as
  the table above, `cl-log-kit` came in ~1.3x slower (477 ns/call vs
  370 ns/call, both 0 bytes/call), and the honest framing is that the gap is
  the genuine cost of work the comparable `log4cl` path does not do at all:
  escaping and anti-spoofing every token, writing a structured per-field
  record, and guaranteeing on every call the deep cycle-checked snapshot,
  canonical-key deduplication, reentrant thread-safe stream serialization,
  and structured resource limits. This library does not claim to be the
  fastest Common Lisp logger in an unqualified sense; matching that would
  mean dropping the guarantees it exists to provide.

### Quality gates

- 179 examples run through [`cl-weave`](https://github.com/nerima-lisp/cl-weave),
  including property-based and fuzz specs, inline snapshots, mutation
  testing, allocation-bound assertions, and real multi-threaded specs for
  the stream and composition lifecycles (not single-threaded approximations
  of them).
- `run-coverage.lisp` fails the build on any coverage regression below
  93.85% expression / 98.7% branch; the suite currently reaches 93.95% /
  98.77%. 100% is not the target and is not reachable here: every remaining
  uncovered span is a declarative form with no runtime execution model
  (`defconstant`, `defclass`/`defstruct` slot lists, `defpackage` export
  lists, docstrings) or a `defmacro` body, which runs at macroexpansion time
  and is invisible to `sb-cover`'s runtime instrumentation by construction.
- `nix flake check` runs the same suite a contributor runs locally, with
  timeout enforcement via
  [`cl-process-kit`](https://github.com/nerima-lisp/cl-process-kit) rather
  than a shell `timeout` a caller has to remember. Every CI job carries a
  `timeout-minutes` bound.
- The shipped `cl-log-kit` system depends on nothing but ASDF ≥ 3.3.1 and
  SBCL. `cl-weave`, `cl-json-kit`, and `cl-process-kit` are test- and
  dev-only, and the flake pins each to the tag matching the `.asd`'s own
  version floor.
- A full MkDocs (Material) documentation site, built `--strict` inside the
  Nix sandbox so a broken link or unlisted page fails the build.

[1.0.0]: https://github.com/nerima-lisp/cl-log-kit/releases/tag/v1.0.0
