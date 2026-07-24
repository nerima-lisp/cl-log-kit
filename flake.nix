{
  description = "Dependency-free, SBCL-only structured logging toolkit for Common Lisp";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # paredit-cli is a dev-lint input of the nerima-lisp packages below, whose
    # flakes still point at the pre-move github:takeokunn/paredit-cli URL. It
    # never reaches cl-log-kit's CL_SOURCE_REGISTRY, but pin every transitive
    # copy to the current github:nerima-lisp org so this lock carries no
    # takeokunn references.
    paredit-cli = {
      url = "github:nerima-lisp/paredit-cli";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    cl-weave = {
      url = "github:nerima-lisp/cl-weave";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.paredit-cli.follows = "paredit-cli";
    };
    cl-process-kit = {
      url = "github:nerima-lisp/cl-process-kit";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-weave.inputs.paredit-cli.follows = "paredit-cli";
    };
    # Test-only: an independent JSON parser the json-handler specs use to
    # assert emitted output parses back to the expected structure. Not a
    # dependency of the shipped cl-log-kit system.
    cl-json-kit = {
      url = "github:nerima-lisp/cl-json-kit";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.cl-weave.inputs.paredit-cli.follows = "paredit-cli";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      cl-weave,
      cl-process-kit,
      cl-json-kit,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      # cl-weave and cl-process-kit are the real, upstream dependencies (not
      # vendored): their flake source trees are appended to
      # CL_SOURCE_REGISTRY so ASDF resolves both the same way in
      # `nix develop`, `nix flake check`, and the packaged apps.
      # cl-process-kit backs only run-ci.lisp's timeout enforcement — it is
      # not a dependency of the cl-log-kit or cl-log-kit/test systems, so
      # the shipped library stays dependency-free.
      sourceRegistry = "${self}//:${cl-weave}//:${cl-process-kit}//:${cl-json-kit}//";
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
            version = "1.1.0";
            src = self;
            systems = [ "cl-log-kit" ];
          };
          default = cl-log-kit;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = pkgs.runCommand "cl-log-kit-tests"
            {
              nativeBuildInputs = [ pkgs.sbcl ];
              CL_SOURCE_REGISTRY = sourceRegistry;
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME" "$out"
              sbcl --script ${self}/run-ci.lisp tests
              touch "$out/passed"
            '';
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # Runs through run-ci.lisp, which enforces a real, escalating
          # (SIGTERM then SIGKILL) timeout on the underlying sbcl child
          # process via nerima-lisp/cl-process-kit, instead of relying on a
          # caller to remember to prepend `timeout 120s`.
          #
          # There is deliberately no `coverage` app here: `nix run` executes
          # against an immutable, read-only copy of the source under
          # /nix/store, and run-coverage.lisp needs to write coverage/
          # next to the source it instruments. Coverage stays a `nix
          # develop` workflow (`sbcl --script run-ci.lisp coverage`), where
          # the working tree is real and writable; see README.md.
          test = pkgs.writeShellApplication {
            name = "cl-log-kit-test";
            runtimeInputs = [ pkgs.sbcl ];
            text = ''
              export CL_SOURCE_REGISTRY="${sourceRegistry}"
              exec sbcl --script ${self}/run-ci.lisp tests
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
            ];
            CL_SOURCE_REGISTRY = sourceRegistry;
          };
        }
      );
    };
}
