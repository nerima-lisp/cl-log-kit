# Contributing to cl-log-kit

Thank you for improving `cl-log-kit`. This project values small, reviewable
changes with a clear user-facing reason and reproducible validation.

## Before You Start

- Read the [documentation site](https://nerima-lisp.github.io/cl-log-kit/),
  or `docs/src/` in the repository.
- Discuss substantial public-API changes in an issue before investing in an
  implementation. The exported surface is versioned under
  [Semantic Versioning](https://semver.org/spec/v2.0.0.html): a change to the
  shape or behavior of any exported symbol needs a major version and a
  documented migration path, so it is worth agreeing on the shape first.
- Do not report security vulnerabilities in public issues. Follow
  [SECURITY.md](SECURITY.md) instead.

## Two Constraints Worth Knowing Up Front

Both are load-bearing, and a change that violates either will be asked to
change rather than to justify itself:

1. **The shipped `cl-log-kit` system has zero runtime dependencies** —
   nothing but ASDF ≥ 3.3.1 and SBCL. `cl-weave`, `cl-json-kit`, and
   `cl-process-kit` are used by `cl-log-kit/test` and the CI scripts only.
   A new dependency on the library system is a design change, not a detail.
2. **`handle-log-record` is the only place a handler writes output.** The
   protocol exists to make "this log line was printed twice" structurally
   impossible; a second write path defeats it.

## Development Environment

Nix provides the supported development environment and toolchain:

```sh
nix develop
nix flake check --print-build-logs
```

Without Nix, point `CL_SOURCE_REGISTRY` at the test dependencies yourself:

```sh
CL_SOURCE_REGISTRY="/path/to/cl-weave//:/path/to/cl-process-kit//:/path/to/cl-json-kit//:$(pwd)//:" \
  sbcl --script run-ci.lisp tests
```

`run-ci.lisp` runs the suite as a child process under a real, escalating
(SIGTERM then SIGKILL) timeout, so a hang fails fast instead of stalling a
CI job. See [README.md](README.md#testing) for the full set of entry points.

## Tests and Coverage

- Add or update specs for every behavior change. The suite is
  [`cl-weave`](https://github.com/nerima-lisp/cl-weave)-based and lives in
  `t/`, mirroring `src/` file by file.
- Concurrency behavior is tested with real threads, not single-threaded
  approximations. If you touch `handler.lisp` or `lifecycle.lisp`, run the
  suite several times — those files' history is the reason that convention
  exists.
- The coverage gate fails the build on a regression:

  ```sh
  nix develop -c sbcl --script run-ci.lisp coverage 180
  ```

  Coverage needs a writable working tree, which is why there is no
  `nix run .#coverage`. **Lowering a floor in `run-coverage.lisp` requires
  an explanation of what became unmeasurable and why**, not a quiet edit —
  the comment at the top of that file records the existing accounting.

## Pull Requests

- Keep a pull request focused on one problem.
- Update `CHANGELOG.md` and, when the public surface or documented behavior
  moves, `docs/src/`.
- Every exported symbol carries a docstring. A new one is not finished
  without it.
- State the commands you ran, and say plainly if something could not be run.
