# Development

## Two constraints worth knowing up front

Both are load-bearing, and a change that violates either will be asked to
change rather than to justify itself:

1. **The shipped `cl-log-kit` system has zero runtime dependencies** —
   nothing but ASDF 3.3.1 or newer and SBCL. `cl-weave` and `cl-json-kit` are
   used by `cl-log-kit/test` only. A new dependency on the library system is
   a design change, not a detail.
2. **`handle-log-record` is the only place a handler writes output.** The
   protocol exists to make "this log line was printed twice" structurally
   impossible; a second write path defeats it.

## Environment

Nix provides the supported toolchain. The dev shell wires
`CL_SOURCE_REGISTRY` up to the test-only dependencies automatically:

```sh
nix develop          # SBCL, paredit-cli, and CL_SOURCE_REGISTRY
nix run .#test       # run the test suite under a two-minute timeout
nix flake check      # tests + formatting + docs, the same gate CI uses
nix fmt              # format Nix sources (treefmt)
nix build .#docs     # build this site with mkdocs --strict
```

Without Nix, point `CL_SOURCE_REGISTRY` at the two test dependencies
yourself. `timeout` is an optional outer guard, not a requirement of the
suite; on systems without it, drop the prefix:

```sh
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-json-kit//:$(pwd)//:" \
  timeout 120s sbcl --script run-tests.lisp
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-json-kit//:$(pwd)//:" \
  timeout 120s sbcl --script run-coverage.lisp
```

`cl-log-kit/test` requires `cl-weave` 1.0.0 or newer and `cl-json-kit` 1.0.0
or newer. The flake pins both, so only a hand-managed `CL_SOURCE_REGISTRY`
can point at an older checkout.

## Coverage gate

Coverage needs a writable working tree, which is why there is no
`nix run .#coverage`: `nix run` executes against an immutable copy of the
source under `/nix/store`, and `run-coverage.lisp` writes `coverage/` next to
the source it instruments. Run it from the dev shell instead:

```sh
nix develop -c sbcl --script run-coverage.lisp
```

`run-coverage.lisp` runs the suite through `cl-weave:run-all`'s native
`:coverage` support and **fails the build if coverage regresses** below the
floors set in that file — 93.85% expression / 98.7% branch. The suite
actually reaches 93.95% / 98.77%; the floors sit just below that so ordinary
platform variance in sb-cover's own accounting cannot trip the gate
spuriously while a real regression still does.

**Lowering a floor requires an explanation of what became unmeasurable and
why**, not a quiet edit. The comment at the top of `run-coverage.lisp`
records the existing accounting.

Read the expression figure with two structural costs in mind, both
deliberate:

- **CPS helper pairs.** Extracting a repeated `with-mutex` or cycle-marking
  form into a `%call-with-…`/`with-…` pair moves that logic behind one more
  `defmacro` body — better code, and a body sb-cover's runtime
  instrumentation cannot observe.
- **Docstrings.** All 101 exported symbols carry one, and sb-cover counts a
  docstring literal as an expression it can never see execute: the *covered*
  count is untouched while the total rises.

Every remaining gap above the floor is confirmed non-executable by
construction — a `defconstant`, `defclass`/`defstruct` slot list,
`defpackage` export list, `in-package` form, or a `defmacro`/
`define-condition` body — not an unexamined shortfall. The HTML report is
written to `coverage/cover-index.html`.

## Test-writing techniques

Tests live in `t/`, mirroring `src/` file by file. Beyond ordinary
`describe`/`it`/`expect` specs, this suite uses several of `cl-weave`'s more
advanced facilities rather than hand-rolling equivalents:

- **Domain matchers.** `t/helpers-matchers.lisp` registers `cl-weave:expect-extend`
  matchers (`:to-have-field`, `:to-have-field-matching`, `:to-lack-field`,
  `:to-be-single-line`, `:to-have-recorded`, `:to-contain-substring`) so
  specs read as `(expect fields :to-have-field :k "v")` instead of manually
  destructuring an alist in every test — the framework gains a `log-kit`
  vocabulary without knowing anything about `log-kit` itself.
- **Property-based testing.** `t/property-test.lisp` uses `it-property` with
  `cl-weave` generators (`gen-integer`, `gen-string`, `gen-recursive`,
  `gen-one-of`, ...) to state invariants that must hold for every generated
  input — that `level<`/`level<=` agree with plain integer comparison, or
  that the recursive field snapshot is a structure-sharing-free copy — rather
  than relying only on hand-picked examples.
- **Fuzzing with a bounded budget.** `it-fuzz` runs the text handler against
  200 generated `(:trials 200 :timeout-per-trial 2)` key/value combinations
  to prove it never signals regardless of input shape, with each trial
  individually time-bounded so a pathological generated value cannot hang the
  suite.
- **Mutation testing.** `cl-weave:run-mutations`/`assert-mutation-score`
  generate every one-operator mutant of a small reference expression and
  require the library's own `level<`/`level<=` to kill every one of them,
  proving those wrappers introduce zero drift from plain integer comparison.
- **Inline snapshot testing.** `:to-match-inline-snapshot` pins a rendered
  value's exact textual form directly in the spec, so a future accidental
  format change shows up as a snapshot diff instead of a silent pass.

Concurrency behavior is tested with real threads, not single-threaded
approximations. If you touch `handler.lisp` or `lifecycle.lisp`, run the
suite several times — those files' history is the reason that convention
exists.

See `cl-weave`'s own [documentation](https://nerima-lisp.github.io/cl-weave/)
for the full DSL guide, matcher reference, and the property-testing,
mutation-testing, and mocking pages.

## Pull requests

- Keep a pull request focused on one problem, and discuss substantial
  public-API changes in an issue first. A change to an exported symbol needs
  a major version and a documented migration path, so it is worth agreeing on
  the shape before the implementation.
- Add or update specs for every behavior change.
- Update `CHANGELOG.md` and, when the public surface or documented behavior
  moves, the affected pages under `docs/src/`.
- Every exported symbol carries a docstring. A new one is not finished
  without it.
- State the commands you ran, and say plainly if something could not be run.

The org-wide process lives in
[CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md).

## CI

The published GitHub Actions workflow runs `nix flake check`, which evaluates
three derivations in parallel: the SBCL suite (`checks.default`), the treefmt
formatting gate (`checks.formatting`), and the `mkdocs --strict` build of this
site (`checks.docs`). That is the same gate a contributor runs locally,
executed as a reproducible build.
