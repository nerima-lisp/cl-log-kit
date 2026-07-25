{
  description = "Dependency-free, SBCL-only structured logging toolkit for Common Lisp";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it only advances after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Sibling packages consumed purely as ASDF source are pulled with
    # `flake = false`. Their own flake.nix is then never evaluated, so this
    # lock stays free of their transitive input closures instead of dragging
    # in a second cl-weave at a different tag, as it previously did.
    #
    # Every one of these is test/dev-only. The shipped cl-log-kit system
    # depends on nothing but ASDF, and that is the property the package is
    # built around.

    # Test framework. Pinned to the tag matching cl-log-kit.asd's
    # (:version "cl-weave" "1.0.0") floor on the cl-log-kit/test system; bump
    # this ref in lockstep with any future bump of that floor.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.0.0";
      flake = false;
    };

    # Test-only: an independent JSON parser the json-handler specs use to
    # assert emitted output parses back to the expected structure rather than
    # merely containing the right substrings. Pinned to the .asd floor, as
    # cl-weave above.
    cl-json-kit = {
      url = "github:nerima-lisp/cl-json-kit/v1.0.0";
      flake = false;
    };

    # The structural-refactoring CLI contributors run by hand. Kept as a real
    # flake because devShells.default consumes its package output, not its
    # source tree; it is a Rust binary and never reaches CL_SOURCE_REGISTRY.
    paredit-cli = {
      url = "github:nerima-lisp/paredit-cli/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.treefmt-nix.follows = "treefmt-nix";
    };

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      paredit-cli,
      cl-weave,
      cl-json-kit,
      treefmt-nix,
      ...
    }:
    let
      # x86_64-linux is what CI builds. aarch64-darwin is declared as well
      # because it is the platform the benchmark figures in the docs were
      # measured on and where the suite is run before every release, so it is
      # verified rather than merely hoped for.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      # cl-weave and cl-json-kit are appended to CL_SOURCE_REGISTRY so ASDF
      # resolves them identically in `nix develop`, `nix flake check`, and the
      # packaged apps.
      sourceRegistry = "${self}//:${cl-weave}//:${cl-json-kit}//";

      # Single source of truth for the version: the :version form in
      # cl-log-kit.asd. A release edits that one line and every Nix package
      # follows; release.yml refuses to publish a tag that disagrees with it.
      # Nix regexes are anchored to the whole string and `.` never spans
      # newlines, so the value is extracted line-by-line rather than with one
      # multi-line match.
      version =
        let
          lines = nixpkgs.lib.splitString "\n" (builtins.readFile ./cl-log-kit.asd);
          versionLine = builtins.head (
            builtins.filter (line: builtins.match "[[:space:]]*:version \"[^\"]*\"" line != null) lines
          );
        in
        builtins.head (builtins.match "[[:space:]]*:version \"([^\"]*)\"" versionLine);

      # treefmt drives `nix fmt` and the checks.formatting gate. Scope is Nix
      # only: a YAML formatter mangles the GitHub Actions `on:` key, and
      # reformatting Markdown would churn every page in docs/src for no
      # reviewable gain.
      treefmtEval = forAllSystems (
        system:
        treefmt-nix.lib.evalModule nixpkgs.legacyPackages.${system} {
          projectRootFile = "flake.nix";
          programs.nixfmt.enable = true;
        }
      );
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        rec {
          cl-log-kit = pkgs.sbcl.buildASDFSystem {
            pname = "cl-log-kit";
            inherit version;
            src = self;
            systems = [ "cl-log-kit" ];
          };
          default = cl-log-kit;

          # Builds docs/ (MkDocs + Material) fully offline: Material bundles
          # all of its assets, so the Nix sandbox needs no network. --strict
          # promotes broken links and pages missing from the nav to build
          # failures.
          #
          # The source root is the repository, not ./docs, because
          # docs/src/changelog.md is a `--8<--` include of the top-level
          # CHANGELOG.md. Keeping one copy is what stops the site's history
          # from falling behind the file GitHub shows on the release page —
          # they had already diverged to 40 lines against 275.
          docs = pkgs.stdenvNoCC.mkDerivation {
            pname = "cl-log-kit-docs";
            inherit version;
            src = pkgs.lib.fileset.toSource {
              root = ./.;
              fileset = pkgs.lib.fileset.unions [
                ./docs/mkdocs.yml
                ./docs/src
                ./CHANGELOG.md
              ];
            };
            nativeBuildInputs = [ pkgs.python3Packages.mkdocs-material ];
            buildPhase = ''
              runHook preBuild
              mkdocs build --strict --config-file docs/mkdocs.yml --site-dir "$out"
              runHook postBuild
            '';
            dontInstall = true;
            meta = {
              description = "Rendered MkDocs (Material) documentation for cl-log-kit";
              homepage = "https://github.com/nerima-lisp/cl-log-kit";
              license = pkgs.lib.licenses.mit;
            };
          };
        }
      );

      # `nix fmt` entry point.
      formatter = forAllSystems (system: treefmtEval.${system}.config.build.wrapper);

      # Granularity lives here, not in extra GitHub Actions jobs: `nix flake
      # check` evaluates each attribute as its own derivation, in parallel,
      # with build caching. Add a check here rather than a job in ci.yml.
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # `timeout` bounds the suite so a reintroduced lifecycle deadlock
          # fails the build after two minutes instead of running to the
          # sandbox's own ceiling.
          default =
            pkgs.runCommand "cl-log-kit-tests"
              {
                nativeBuildInputs = [
                  pkgs.sbcl
                  pkgs.coreutils
                ];
                CL_SOURCE_REGISTRY = sourceRegistry;
              }
              ''
                export HOME="$TMPDIR/home"
                mkdir -p "$HOME" "$out"
                timeout 120 sbcl --script ${self}/run-tests.lisp
                touch "$out/passed"
              '';

          # Fails `nix flake check` when any tracked Nix file is unformatted,
          # turning the formatter into an enforced gate rather than a
          # convention.
          formatting = treefmtEval.${system}.config.build.check self;

          # Without this the docs are only ever built by the publish workflow,
          # which runs after a merge to main — so a broken link surfaces as a
          # failed deploy instead of as a failed pull request.
          docs = self.packages.${system}.docs;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # There is deliberately no `coverage` app: `nix run` executes
          # against an immutable copy of the source under /nix/store, and
          # run-coverage.lisp writes coverage/ next to the source it
          # instruments. Coverage stays a `nix develop` workflow, where the
          # working tree is real and writable; see docs/src/development.md.
          test = pkgs.writeShellApplication {
            name = "cl-log-kit-test";
            runtimeInputs = [
              pkgs.sbcl
              pkgs.coreutils
            ];
            text = ''
              export CL_SOURCE_REGISTRY="${sourceRegistry}"
              exec timeout 120 sbcl --script ${self}/run-tests.lisp
            '';
          };
        in
        {
          default = {
            type = "app";
            program = "${test}/bin/cl-log-kit-test";
          };
          test = {
            type = "app";
            program = "${test}/bin/cl-log-kit-test";
          };
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.sbcl
              paredit-cli.packages.${system}.default
            ];
            CL_SOURCE_REGISTRY = sourceRegistry;
          };
        }
      );
    };
}
