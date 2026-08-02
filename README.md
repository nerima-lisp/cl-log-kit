# cl-log-kit

[![CI](https://github.com/nerima-lisp/cl-log-kit/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/nerima-lisp/cl-log-kit/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Documentation](https://img.shields.io/badge/docs-MkDocs%20Material-0a7a5a)](https://nerima-lisp.github.io/cl-log-kit/)

An SBCL-only structured logging toolkit for Common Lisp, modelled on Go's
`log/slog`. It separates immutable log *records* from the *handlers* that
serialize them: every built-in handler emits a record through exactly one
`handle-log-record` method, so a line cannot reach output twice by two paths.
Field snapshotting is deep, cycle-safe, and bounded, so a logging call stays
safe on attacker-influenced values. Built on the nerima-lisp toolkit family —
[`cl-date-kit`](https://github.com/nerima-lisp/cl-date-kit) for calendar/zone
handling, [`cl-concurrent-kit`](https://github.com/nerima-lisp/cl-concurrent-kit)
for locking and atomics, and
[`cl-host-kit`](https://github.com/nerima-lisp/cl-host-kit) for filesystem
operations — used directly, with no adapter layer in between.

Full documentation is published at <https://nerima-lisp.github.io/cl-log-kit/>.
The source for that site lives in [docs/src/](docs/src/).

## Quick Start

```lisp
(defpackage #:my-app
  (:use #:cl #:log-kit)
  (:shadowing-import-from #:log-kit #:log))
(in-package #:my-app)

(defparameter *logger*
  (make-logger :name "api"
               :handler (make-instance 'json-handler)
               :level +level-info+
               :fields '(:service "orders")))

(log-info *logger* "server started" :port 8080)
;; => {"time":...,"level":"INFO","logger":"api","message":"server started",
;;     "fields":{"port":8080,"service":"orders"}}

(defparameter *request-logger* (logger-with *logger* :request-id "abc123"))

(log-warn *request-logger* "slow response" :duration-ms 842)
```

`logger-with` returns a new logger; call-site fields override logger fields
with the same case-insensitive canonical name. Continue with
[Quick Start](https://nerima-lisp.github.io/cl-log-kit/quick-start/).

## Install

```nix
# flake.nix
inputs.cl-log-kit = {
  url = "github:nerima-lisp/cl-log-kit/v2.0.1";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Note the pinned tag. Consumers inside this org pin a release tag rather than
follow the default branch.

With plain ASDF, clone the repository somewhere ASDF can find it and load the
system:

```lisp
(asdf:load-system "cl-log-kit")
```

See [Installation](https://nerima-lisp.github.io/cl-log-kit/installation/) for
both paths in full.

## Documentation

- [Quick Start](https://nerima-lisp.github.io/cl-log-kit/quick-start/) — a
  first logger, a first log line, JSON output.
- [Handlers](https://nerima-lisp.github.io/cl-log-kit/handlers/) — text and
  JSON output, composition, rotation, buffering, and the lifecycle protocol.
- [API Reference](https://nerima-lisp.github.io/cl-log-kit/api-reference/) —
  every exported symbol, grouped by area.
- [Compatibility](https://nerima-lisp.github.io/cl-log-kit/compatibility/) —
  supported platforms, the stability promise, and the security scope.

## Development

```sh
nix develop          # SBCL with CL_SOURCE_REGISTRY already set
nix run .#test       # run the test suite
nix flake check      # tests + formatting + docs, the same gate CI uses
nix fmt              # format Nix sources (treefmt)
```

Tests live in `t/` and run under
[cl-weave](https://github.com/nerima-lisp/cl-weave), the org's test
framework. Coverage runs from the dev shell, because it writes next to the
source it instruments:

```sh
nix develop -c sbcl --script run-coverage.lisp
```

The coverage gate fails the build on a regression below the floors recorded
in `run-coverage.lisp`. See
[Development](https://nerima-lisp.github.io/cl-log-kit/development/) for the
non-Nix invocation, the coverage accounting, and the `cl-weave` facilities
this suite uses.

## Contributing

One constraint is load-bearing: `handle-log-record` is the only place a
handler writes output. A change that violates it will be asked to change
rather than to justify itself. Runtime dependencies are limited to the
nerima-lisp toolkit family (see `cl-log-kit.asd`); a new dependency from
outside that family needs a real reason, not just convenience.

See the org-wide
[CONTRIBUTING](https://github.com/nerima-lisp/.github/blob/main/CONTRIBUTING.md)
guide and the
[package standard](https://github.com/nerima-lisp/.github/blob/main/PACKAGE_STANDARD.md).

## Support

See [SUPPORT](https://github.com/nerima-lisp/.github/blob/main/SUPPORT.md).
Report vulnerabilities privately through
[GitHub security advisories](https://github.com/nerima-lisp/cl-log-kit/security/advisories/new),
never in a public issue.

## License

MIT. See [LICENSE](LICENSE).
