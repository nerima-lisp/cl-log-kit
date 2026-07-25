# Support

- Start with the [documentation site](https://nerima-lisp.github.io/cl-log-kit/):
  [Quick Start](https://nerima-lisp.github.io/cl-log-kit/quick-start/),
  [Handlers](https://nerima-lisp.github.io/cl-log-kit/handlers/), and the
  [API Reference](https://nerima-lisp.github.io/cl-log-kit/api-reference/).
  Every exported symbol also carries a docstring, so `(documentation 'log-info 'function)`
  answers at the REPL.
- Report reproducible defects, documentation gaps, and concrete feature
  requests through
  [GitHub Issues](https://github.com/nerima-lisp/cl-log-kit/issues/new/choose).
- Send fixes that can be described and validated locally as pull requests;
  see [CONTRIBUTING.md](CONTRIBUTING.md).
- Report security vulnerabilities privately through
  [GitHub Security Advisories](https://github.com/nerima-lisp/cl-log-kit/security/advisories/new).

Do not include vulnerability details in public issues or discussions.

## Supported Environment

SBCL only, on the platforms the flake builds (`x86_64-linux` and
`aarch64-darwin`). The library uses `sb-thread`, `sb-gray`, `sb-ext`, and
`sb-debug` directly for its locking, bounded output streams, atomics, and
backtrace capture, so it is deliberately not portable Common Lisp.

## What to Include in a Report

The smallest form that reproduces it, plus your SBCL version. For anything
involving concurrency, ordering, or a hang, say how many threads were
involved and whether it reproduces every run — that distinction usually
determines where to look first.
