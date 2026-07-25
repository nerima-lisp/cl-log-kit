# Installation

!!! info "Prerequisites"

    `cl-log-kit` targets [SBCL](https://www.sbcl.org/) and requires ASDF
    3.3.1 or newer (a modern SBCL already bundles a recent-enough ASDF). The
    shipped `cl-log-kit` system is dependency-free — no third-party library
    is loaded at runtime.

Pick the path that matches how you use the library.

=== "ASDF (manual clone)"

    Clone the repository somewhere ASDF can find it, then load the system:

    ```sh
    git clone https://github.com/nerima-lisp/cl-log-kit.git
    ```

    ```lisp
    (asdf:load-system "cl-log-kit")
    ```

    ASDF finds the system if the clone is on `CL_SOURCE_REGISTRY` or under a
    directory ASDF already searches (e.g. `~/common-lisp/` or
    `~/.local/share/common-lisp/source/`).

=== "Nix flake"

    Build the packaged ASDF system directly:

    ```sh
    nix build github:nerima-lisp/cl-log-kit
    ```

    The build output's root is the ASDF source tree — `result/cl-log-kit.asd`
    sits at the top level. Reference `cl-log-kit` from your own flake as an
    input and append its store path to `CL_SOURCE_REGISTRY`:

    ```nix
    CL_SOURCE_REGISTRY = "${cl-log-kit}//:${CL_SOURCE_REGISTRY:-}";
    ```

    or, from the command line:

    ```sh
    CL_SOURCE_REGISTRY="$(nix build github:nerima-lisp/cl-log-kit --print-out-paths --no-link)//:"
    ```

=== "Local checkout (contributors)"

    Clone the repository, then work inside the reproducible dev shell, which
    wires up the test-only dependencies automatically:

    ```sh
    git clone https://github.com/nerima-lisp/cl-log-kit.git
    cd cl-log-kit
    nix develop                 # SBCL + CL_SOURCE_REGISTRY for cl-weave
                                 # and cl-json-kit
    nix run .#test               # run the test suite with a real timeout
    nix flake check               # every CI entrypoint
    ```

    `run-tests.lisp` and `run-coverage.lisp` also work
    without Nix — see [Development](development.md) for the direct
    `CL_SOURCE_REGISTRY` invocation. `cl-log-kit/test` requires `cl-weave`
    1.0.0 or newer and `cl-json-kit` 1.0.0 or newer; the flake pins both, so
    only a hand-managed `CL_SOURCE_REGISTRY` can point at an older checkout.

## Runtime Support

`cl-log-kit` is developed and tested against SBCL. The library itself has no
third-party runtime dependencies, so it should load cleanly on any modern
ASDF 3.3.1+ setup; SBCL is the only implementation the test suite and CI
pipeline exercise. See [Compatibility](compatibility.md) for the platforms
the flake builds and the stability promise attached to the exported surface.

## Package and Naming

Load the system, then `:use` the `log-kit` package:

```lisp
(defpackage #:my-app
  (:use #:cl #:log-kit)
  (:shadowing-import-from #:log-kit #:log))
(in-package #:my-app)
```

`log-kit` shadows the common-lisp `log` symbol for its own `log` macro, the
arbitrary-level general form behind `log-debug`/`log-info`/etc. That symbol
is internal, so `:use`-ing `log-kit` alone leaves `cl:log` (the logarithm)
accessible; the `:shadowing-import-from` line above is what makes `log-kit`'s
macro available under that name instead, and can be dropped if you only use
the fixed-level macros.

Continue with [Quick Start](quick-start.md) to build your first logger.
