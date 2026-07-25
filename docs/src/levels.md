# Levels

```text
DEBUG (0) < INFO (10) < WARN (20) < ERROR (30) < FATAL (40)
```

The five built-in severities are plain integer ranks, not a keyword-plus-alist
lookup, so filtering is a simple numeric comparison:

```lisp
+level-debug+   ; 0
+level-info+    ; 10
+level-warn+    ; 20
+level-error+   ; 30
+level-fatal+   ; 40
```

A logger's minimum threshold defaults to `+level-info+`. Integer custom
levels are also accepted — anything that is not one of the five standard
values is rendered numerically instead of by name.

## Public operations

- `(level-name level)` — the canonical name (`"DEBUG"`, `"INFO"`, …), or the
  integer printed as a string for a custom level.
- `(level< a b)` — true when level `a` ranks strictly below level `b`.
- `(level<= a b)` — true when level `a` ranks at or below level `b`.
- `(log-enabled-p logger level)` — true when `level` passes `logger`'s
  threshold; the check every logging macro performs before doing anything
  else.

## Level-gated evaluation

Every logging macro (`log-debug`, `log-info`, `log-warn`, `log-error`,
`log-fatal`, the `log-default-*` family, `log-condition`, and
`with-log-span`) tests the level **before** evaluating anything else. A
filtered call:

- never evaluates the message form
- never evaluates the field-list forms
- never touches the logger's clock
- never reaches the handler

This means it is safe to pass expensive expressions to a log call that might
be filtered out — a `log-debug` call in a production logger set to
`+level-info+` costs one integer comparison, nothing more.

The logger expression itself in an explicit call (e.g. `*logger*` in
`(log-info *logger* ...)`) is still evaluated exactly once, regardless of
whether the level is enabled — so it is safe to pass a form with side
effects there, but not necessary or expected.

```lisp
(log-debug *logger* (expensive-computation) :detail (build-large-plist))
;; expensive-computation and build-large-plist are never called
;; when *logger*'s level is above DEBUG.
```
