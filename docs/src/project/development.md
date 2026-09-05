# Development

## Constraints

1. **The shipped `cl-log-kit` system's runtime dependencies are limited to
   the nerima-lisp toolkit family** — ASDF 3.3.1+, SBCL, `cl-date-kit`,
   `cl-concurrent-kit`, and `cl-host-kit`, each used directly with no
   adapter layer. `cl-weave` and `cl-json-kit` are used by `cl-log-kit/test`
   only. A dependency from outside that family changes the supported design.
2. **`handle-log-record` is the only place a handler writes output.** A second
   write path could duplicate a log line.

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

`cl-log-kit/test` requires `cl-weave` 1.3.0 or newer and `cl-json-kit` 1.2.0
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
`:coverage` support and fails below the floors set in that file: 94.9%
expression / 98.45% branch. The current measured values are recorded by the
coverage run; the HTML report is written to `coverage/cover-index.html`.

The comment at the top of `run-coverage.lisp` records the accounting behind
the floors. Explain any reduction in a floor there.

Two structural costs affect the expression figure:

- **CPS helper pairs.** A `%call-with-…`/`with-…` pair puts the helper body
  behind a `defmacro`, which sb-cover's runtime instrumentation cannot observe.
- **Docstrings.** sb-cover counts each docstring literal as an expression,
  although runtime instrumentation cannot observe it.

The remaining uncovered forms are definitions or macro bodies that runtime
instrumentation cannot observe.

## Test-writing techniques

Tests live in `t/`, mirroring `src/` file by file. The suite also uses
`cl-weave` facilities:

- **Domain matchers.** `t/helpers-matchers.lisp` registers `cl-weave:expect-extend`
  matchers (`:to-have-field`, `:to-have-field-matching`, `:to-lack-field`,
  `:to-be-single-line`, `:to-have-recorded`, `:to-contain-substring`) so
  specs read as `(expect fields :to-have-field :k "v")` instead of manually
  destructuring an alist in every test.
- **Property-based testing.** `t/property-test.lisp` uses `it-property` with
  `cl-weave` generators (`gen-integer`, `gen-string`, `gen-recursive`,
  `gen-one-of`, ...) to state invariants that must hold for every generated
  input. Examples include agreement between `level<`/`level<=` and plain
  integer comparison, and structure-sharing-free recursive field snapshots.
- **Fuzzing with a bounded budget.** `it-fuzz` runs the text handler against
  200 generated `(:trials 200 :timeout-per-trial 2)` key/value combinations
  and checks that it does not signal for any generated input shape. Each trial
  is time-bounded.
- **Mutation testing.** `cl-weave:run-mutations`/`assert-mutation-score`
  generate every one-operator mutant of a small reference expression and
  require the library's own `level<`/`level<=` to kill every one, checking that
  the wrappers match plain integer comparison.
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
  a major version and a documented migration path, so agree on the shape before
  implementation.
- Add or update specs for every behavior change.
- When the public surface or documented behavior moves, update the affected
  pages under `docs/src/`. Release history is not kept in the tree: it lives
  in the GitHub Release description, written when the tag is published.
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
