{
  description = "SBCL-only structured logging toolkit for Common Lisp";

  inputs = {
    # nixos-unstable, not nixpkgs-unstable: it only advances after the NixOS
    # release tests pass, so it is less likely to land a broken build.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # `inputs.nixpkgs.follows` is mandatory on every input below: without it
    # each one drags in its own nixpkgs, inflating flake.lock and rebuilding
    # the same derivations.

    # The org's own "crane for Common Lisp/ASDF": turns this repository's .asd
    # into a Nix derivation and generates the whole packages/checks/apps/
    # devShells/formatter/overlays output table from one mkPackageFlake call
    # below, instead of hand-rolling each of them.
    cl-nix-forge = {
      url = "github:nerima-lisp/cl-nix-forge/v0.4.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Runtime dependency: calendar/time-zone handling for
    # rotating-file-handler's date-bucket derivation. Pinned to the tag
    # matching cl-log-kit.asd's (:version "cl-date-kit" "0.2.0") floor.
    # `cl-nix-forge.follows` keeps every sibling's dependency-ancestry
    # bookkeeping (lib/core/dedup.nix) built by the SAME cl-nix-forge
    # revision as this flake's own `lispDerivation` call; without it, two
    # different revisions' `ancestry` shapes can disagree and
    # `lib.core.dedup.ancestryWalker` fails with "attribute 'ancestry'
    # missing" trying to walk a dependency's subtree built by the other one.
    cl-date-kit = {
      url = "github:nerima-lisp/cl-date-kit/v0.2.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    # Runtime dependency: locks/condition-variables/atomic counters
    # underlying the handler protocol's stream-state and close-once
    # lifecycle. Pinned to the tag matching cl-log-kit.asd's
    # (:version "cl-concurrent-kit" "0.1.0") floor.
    cl-concurrent-kit = {
      url = "github:nerima-lisp/cl-concurrent-kit/v0.3.0";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    # Runtime dependency: directory listing/deletion/path-confinement for
    # rotating-file-handler's retention pruning. Pinned to the tag matching
    # cl-log-kit.asd's (:version "cl-host-kit" "0.2.0") floor.
    cl-host-kit = {
      url = "github:nerima-lisp/cl-host-kit/v0.2.5";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    # Test framework, a check-only dependency (see cl-log-kit.asd's
    # cl-log-kit/test system). Pinned to the tag matching the .asd floor.
    cl-weave = {
      url = "github:nerima-lisp/cl-weave/v1.1.4";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    # Test-only: an independent JSON parser the json-handler specs use to
    # assert emitted output parses back to the expected structure rather than
    # merely containing the right substrings. Pinned to the .asd floor, as
    # cl-weave above.
    cl-json-kit = {
      url = "github:nerima-lisp/cl-json-kit/v1.0.2";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-nix-forge.follows = "cl-nix-forge";
    };

    # The structural-refactoring CLI contributors run by hand. Consumed only
    # as an interactive devShell package, never as a Lisp dependency.
    paredit-cli = {
      url = "github:nerima-lisp/paredit-cli/v1.4.0";
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
      cl-nix-forge,
      cl-date-kit,
      cl-concurrent-kit,
      cl-host-kit,
      cl-weave,
      cl-json-kit,
      paredit-cli,
      treefmt-nix,
    }:
    let
      lib = nixpkgs.lib;

      # x86_64-linux is what CI gates; aarch64-darwin is the development
      # machine. Every per-system output -- packages, checks, apps AND devShells
      # -- comes from this one list, so leaving aarch64-darwin out takes `nix
      # build` and `nix develop` off the development machine as well. That trade
      # was made on 2026-08-01 and reverted on 2026-08-02; aarch64-darwin carries
      # no CI gate, which PACKAGE_STANDARD.md's "systems" section accepts
      # explicitly. aarch64-linux and x86_64-darwin are nobody's verification and
      # are not declared.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
    in
    # `mkPackageFlake` spans systems -- it obtains a `pkgs` and its own
    # cl-nix-forge instance per entry in `systems` -- so the per-system `lib`
    # this function is taken from contributes nothing but the function itself.
    cl-nix-forge.lib.${builtins.head systems}.mkPackageFlake {
      inherit self systems nixpkgs;

      pname = "cl-log-kit";

      # Single source of truth for the package version: the :version form in
      # cl-log-kit.asd. A release only ever edits the .asd file and every
      # derivation carrying a version follows automatically. There is
      # deliberately no `version` argument to pass.
      asd = ./cl-log-kit.asd;

      # Spelled out rather than left to `mkPackageFlake`'s documented default
      # of `self`, because that default does not evaluate: a flake's `self`
      # is an attrset with an `outPath`, and `lib.fileset` refuses
      # string-like values. `./.` is the same directory as a path literal.
      root = ./.;

      meta = {
        description = "A slog-inspired structured logging toolkit for Common Lisp built around a Handler protocol";
        homepage = "https://github.com/nerima-lisp/cl-log-kit";
        license = lib.licenses.mit;
        platforms = lib.platforms.unix;
      };

      # Real runtime dependencies (see cl-log-kit.asd's :depends-on): each
      # sibling's own flake builds its ASDF system, so this is an ordinary
      # `lispDependencies` entry rather than a hand-rolled registry string.
      #
      # cl-date-kit's v0.2.0 and cl-host-kit's v0.2.0 tags already build
      # themselves with `mkPackageFlake`, so their package outputs carry
      # cl-nix-forge's own dependency-ancestry metadata as-is.
      # cl-concurrent-kit's v0.1.0 tag still predates that migration, so it
      # needs `fromDerivation` leaf-wrapping until a `mkPackageFlake` release
      # is tagged upstream -- without it, `dedup.nix` cannot merge its
      # ancestry-less output into this package's own dependency tree.
      lispDependencies = ctx: [
        cl-date-kit.packages.${ctx.system}.cl-date-kit
        (ctx.cl.fromDerivation { drv = cl-concurrent-kit.packages.${ctx.system}.cl-concurrent-kit; })
        cl-host-kit.packages.${ctx.system}.cl-host-kit
      ];

      # cl-weave and cl-json-kit are dependencies of cl-log-kit/test and of
      # nothing else (see cl-log-kit.asd), so they are CHECK dependencies:
      # they must not enter the library's closure or the overlay's
      # `pkgs.cl-log-kit`. `packages.*.cl-weave`/`packages.*.cl-json-kit` are
      # each sibling's ASDF SYSTEM, built by its own flake -- a different
      # output from its `packages.*.default` -- so this consumer never
      # compiles either sibling itself.
      #
      # cl-weave's v1.1.0 tag already builds itself with `mkPackageFlake`, so
      # its package output carries cl-nix-forge's ancestry metadata as-is.
      # cl-json-kit's v1.0.1 tag still predates that migration, so it needs
      # the same `fromDerivation` leaf-wrapping as the runtime dependencies
      # above; drop it once a cl-json-kit release built by `mkPackageFlake`
      # is tagged.
      lispCheckDependencies = ctx: [
        cl-weave.packages.${ctx.system}.cl-weave
        (ctx.cl.fromDerivation { drv = cl-json-kit.packages.${ctx.system}.cl-json-kit; })
      ];

      # Drives BOTH `checks.default` and `apps.test`, from this one number,
      # so the command a contributor runs by hand and the gate CI runs
      # cannot drift apart.
      timeoutSeconds = 120;

      # docs/mkdocs.yml + docs/src/, built with `--strict` so a broken link
      # or a page missing from the nav is a build failure.
      #
      # The fileset used to also carry the top-level CHANGELOG.md, which
      # docs/src/changelog.md snippet-included. Both files were abolished in
      # the 2026-08-01 revision: the GitHub Release description is now the
      # only canonical changelog, so there is nothing left to include and
      # pymdownx.snippets is no longer configured.
      docs = {
        root = ./.;
        fileset = lib.fileset.unions [
          ./docs/mkdocs.yml
          ./docs/src
        ];
        mkdocsYmlName = "docs/mkdocs.yml";
      };

      # ONE treefmt evaluation drives `nix fmt` and the `checks.formatting`
      # gate. `evalModule` is passed in rather than closed over so this
      # repository picks its own treefmt-nix version. Scope stays the
      # preset's Nix-only default: nixfmt is a zero-footgun, low-diff
      # formatter, whereas a YAML formatter mangles the GitHub Actions `on:`
      # key and reformatting Markdown would churn every page in docs/src.
      treefmt.evalModule = treefmt-nix.lib.evalModule;

      # The structural-refactoring CLI, interactive-only: it never becomes
      # part of the build, so it belongs here and not in `lispDependencies`.
      # `mkPackageFlake` builds its dev shell from the check-enabled
      # derivation, so `lispCheckDependencies` are already on that shell's
      # registry, which is what makes `nix develop` followed by
      # `sbcl --script run-tests.lisp` work.
      devShellPackages = ctx: [ paredit-cli.packages.${ctx.system}.default ];
    };
}
