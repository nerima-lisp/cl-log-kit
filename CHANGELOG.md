# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - Unreleased

### Added

- Initial rough-draft implementation of `cl-log-kit`, a dependency-free,
  SBCL-only structured logging toolkit inspired by Go's `log/slog`.
- Numeric log levels (`+level-debug+` through `+level-fatal+`) with
  logger-level filtering.
- `log-record` as an immutable snapshot of a single log event.
- A CLOS `handler` protocol (`handle-log-record`) that guarantees each
  record is emitted exactly once, structurally preventing the
  double-print bug found in `cl-cc`'s ad-hoc logger.
- Built-in `text-handler` (`[LEVEL] message key=value ...`) and
  `json-handler` (one escaped JSON object per line) handlers.
- `logger`/`make-logger`/`logger-with` with immutable, chainable bound
  context fields and an injectable `clock` for deterministic testing.
- `*default-logger*` / `set-default-logger` and the `log-debug` /
  `log-info` / `log-warn` / `log-error` / `log-fatal` convenience
  functions.
- Test suite (cl-weave) covering level filtering, single-emission
  guarantees for both handlers, JSON escaping, field immutability, clock
  injection, and the default-logger convenience path.
