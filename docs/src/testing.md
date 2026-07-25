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
floors set in `run-coverage.lisp` — currently 95.0% expression / 98.0%
branch coverage. Every remaining gap above that floor is confirmed
non-executable by construction, or an sb-cover/SBCL instrumentation
artifact; see [CHANGELOG.md](changelog.md) for the line-by-line audit. The
HTML report is written to `coverage/cover-index.html`.

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
