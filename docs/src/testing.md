# Testing and Coverage

The `cl-log-kit/test` ASDF system depends on
[`cl-weave`](https://github.com/nerima-lisp/cl-weave) and
[`cl-json-kit`](https://github.com/nerima-lisp/cl-json-kit) (an independent
JSON parser the `json-handler` specs use to assert emitted output parses
back to the expected structure, not just contains the right substrings).
`run-ci.lisp` also loads [`cl-process-kit`](https://github.com/nerima-lisp/cl-process-kit)
directly, for its own timeout enforcement — not as an ASDF dependency of
either system. Point `CL_SOURCE_REGISTRY` at all three repositories, or use
the flake, which wires this up automatically. All three are test/dev-only —
the `cl-log-kit` system itself stays dependency-free.

## Recommended: `run-ci.lisp`

`run-ci.lisp` runs `run-tests.lisp` or `run-coverage.lisp` as a child SBCL
process via [`cl-process-kit`](https://github.com/nerima-lisp/cl-process-kit),
enforcing a real, escalating (SIGTERM, then SIGKILL after a grace period)
timeout on the child instead of depending on a caller remembering to prepend
a shell `timeout`. It exits `124` if the timeout fires, matching the
`timeout(1)` convention.

```sh
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-process-kit//:/path/to/cl-json-kit//:$(pwd)//:" \
  sbcl --script run-ci.lisp tests              # default timeout: 120s
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-process-kit//:/path/to/cl-json-kit//:$(pwd)//:" \
  sbcl --script run-ci.lisp coverage 180       # explicit timeout in seconds
```

The flake wires up all three test-only dependencies automatically:

```sh
nix run .#test                                          # apps.test, no shell timeout needed
nix develop -c sbcl --script run-ci.lisp coverage 180    # coverage needs a writable working tree
nix flake check
```

There is no `nix run .#coverage`: `nix run` executes against an immutable,
read-only copy of the source under `/nix/store`, and coverage needs to write
`coverage/` next to the source it instruments. Run coverage from `nix
develop` instead, where the working tree is real.

## Coverage gate

`run-coverage.lisp` runs the suite through `cl-weave:run-all`'s native
`:coverage` support and **fails the build if coverage regresses** below the
floors set in `run-coverage.lisp` — currently 93.85% expression / 98.7%
branch coverage. Branch coverage (98.7%) is the highest ever recorded for
this project (see the `## [1.7.0]` entry of [CHANGELOG.md](changelog.md) for
exactly which branches were found and closed to reach it). The expression
floor is lower than 1.7.0's 96.25% not because behavioral coverage
regressed, but because 2.0.0 gave every one of the 101 exported `log-kit`
symbols a docstring: covered-expression count is unchanged (2887 before and
after), while total expression count rose (3000 → 3073) because sb-cover
counts each docstring literal as an expression it can never observe
"executing" — the same declarative, no-runtime-execution-model category as
`defconstant` and `defpackage` export lists. See the `run-coverage.lisp`
comment and the `## [2.0.0]` entry of [CHANGELOG.md](changelog.md) for the
exact accounting. Every remaining gap above the floor is confirmed
non-executable by construction (a `defconstant`, `defclass`/`defstruct` slot
list, `defpackage` export list, `in-package` form, or a
`defmacro`/`define-condition` body — none of which sb-cover's runtime
instrumentation can observe), not an unexamined shortfall; see
[CHANGELOG.md](changelog.md) for the line-by-line audit history. The HTML
report is written to `coverage/cover-index.html`.

## Test-writing techniques

Beyond ordinary `describe`/`it`/`expect` specs, this suite uses several of
`cl-weave`'s more advanced facilities rather than hand-rolling equivalents:

- **Domain matchers.** `t/matchers.lisp` registers `cl-weave:expect-extend`
  matchers (`:to-have-field`, `:to-have-field-matching`, `:to-lack-field`,
  `:to-be-single-line`, `:to-have-recorded`, `:to-contain-substring`) so
  specs read as `(expect fields :to-have-field :k "v")` instead of manually
  destructuring an alist in every test — the framework gains a `log-kit`
  vocabulary without knowing anything about `log-kit` itself.
- **Property-based testing.** `t/property-test.lisp` uses `it-property` with
  `cl-weave` generators (`gen-integer`, `gen-string`, `gen-recursive`,
  `gen-one-of`, ...) to state invariants that must hold for every generated
  input — e.g. that `level<`/`level<=` agree with plain integer comparison,
  or that the recursive field snapshot is a structure-sharing-free copy —
  rather than relying only on hand-picked examples.
- **Fuzzing with a bounded budget.** `it-fuzz` runs the text handler against
  200 generated `(:trials 200 :timeout-per-trial 2)` key/value combinations
  to prove it never signals regardless of input shape, with each trial
  individually time-bounded so a pathological generated value cannot hang
  the suite.
- **Mutation testing.** `cl-weave:run-mutations`/`assert-mutation-score`
  generate every one-operator mutant of a small reference expression (e.g.
  `(< 2 5)`) and require the library's own `level<`/`level<=` to disagree
  with (kill) every one of them, proving those wrappers introduce zero
  drift from plain integer comparison — not just that they pass a few
  hand-picked examples.
- **Inline snapshot testing.** `:to-match-inline-snapshot` pins a rendered
  value's exact textual form directly in the spec (e.g. `level-name`'s
  canonical `"DEBUG"` string), so a future accidental format change shows up
  as a snapshot diff instead of a silent pass.

See `cl-weave`'s own [documentation](https://nerima-lisp.github.io/cl-weave/)
for the full DSL guide, matcher reference, property-testing, mutation-testing,
and mocking pages.

## Direct invocation, without the timeout wrapper

`timeout` below is an optional outer guard, not a requirement of the test
suite itself; on systems without it, run the command without the prefix.

```sh
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-json-kit//:$(pwd)//:" timeout 120s sbcl --script run-tests.lisp
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-json-kit//:$(pwd)//:" timeout 120s sbcl --script run-coverage.lisp
```

## CI

The published GitHub Actions workflow runs `nix flake check`, which drives
`run-ci.lisp tests` inside a Nix derivation with `CL_SOURCE_REGISTRY` pointed
at `cl-weave`, `cl-process-kit`, and `cl-json-kit` — the same test suite a
contributor runs locally, executed as a reproducible build.
