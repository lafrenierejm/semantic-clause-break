{
  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-root.url = "github:srid/flake-root";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-systems = {
      url = "github:nix-systems/default";
      flake = false;
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zig2nix = {
      # https://github.com/Cloudef/zig2nix/pull/60
      url = "github:maxbol/zig2nix/fix/package-args-leak-into-derivation";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.flake-root.flakeModule
        inputs.git-hooks.flakeModule
        inputs.treefmt-nix.flakeModule
      ];
      systems = (import inputs.nix-systems);
      perSystem =
        {
          config,
          self',
          inputs',
          pkgs,
          system,
          ...
        }:
        let
          env = inputs.zig2nix.zig-env.${system} {
            zig = pkgs.zig_0_16;
          };
        in
        {
          apps.check-zig-zon-lock = {
            type = "app";
            meta.description = "Check freshness of build.zig.zon2json-lock.";
            program = pkgs.lib.getExe (
              pkgs.writeShellApplication {
                name = "check-zig-zon-lock";
                runtimeInputs = [ env.zig2nix ];
                text = builtins.readFile ./scripts/check-zig-zon-lock.sh;
              }
            );
          };

          apps.check-markdown-clause-break = {
            type = "app";
            meta.description = "Check that markdown files are split at independent clauses.";
            program = pkgs.lib.getExe' self'.packages.default "semantic-clause-break";
          };

          packages = rec {
            foreign = env.package {
              # binary to be shipped outside of Nix
              name = "semantic-clause-break";
              src = env.pkgs.lib.cleanSource ./.;

              # Packages required for compiling
              nativeBuildInputs = with env.pkgs; [ ];

              # Packages required for linking
              buildInputs = with env.pkgs; [ ];

              # Smaller binaries and avoids shipping glibc.
              zigPreferMusl = true;

              meta.license = pkgs.lib.licenses.mit;
            };
            default = foreign.override (attrs: {
              # Prefer nix friendly settings.
              zigPreferMusl = false;

              # Executables required for runtime.
              # These packages will be added to the PATH.
              zigWrapperBins = with env.pkgs; [ ];

              # Libraries required for runtime.
              # These packages will be added to the LD_LIBRARY_PATH.
              zigWrapperLibs = attrs.buildInputs or [ ];
            });
          };

          checks = {
            zig-tests = self'.packages.default.overrideAttrs (_: {
              doCheck = true;
            });
          };

          pre-commit = {
            check.enable = true;
            settings.package = pkgs.prek;
            settings.hooks = {
              actionlint.enable = true;
              editorconfig-checker.enable = true;
              end-of-file-fixer.enable = true;
              checkmake.enable = true;
              ripsecrets.enable = true;
              trim-trailing-whitespace.enable = true;
              treefmt.enable = true;
              typos.enable = true;
              zig-zon-lock = {
                enable = true;
                name = "build.zig.zon2json-lock up to date";
                description = "Fails if build.zig.zon2json-lock is stale relative to build.zig.zon.";
                files = "^build\\.zig\\.zon$";
                pass_filenames = false;
                entry = self'.apps.check-zig-zon-lock.program;
              };
              markdown-clause-break = {
                enable = true;
                name = "markdown files split at independent clauses";
                description = "Fails if any markdown file has un-split independent clauses (auto-fixed in place).";
                files = "\\.md$";
                pass_filenames = true;
                entry = "${self'.apps.check-markdown-clause-break.program} --fix";
              };
            };
          };

          treefmt.config = {
            projectRootFile = ".git/config";
            package = pkgs.treefmt;
            flakeCheck = false; # use pre-commit's check instead
            programs = {
              nixfmt.enable = true;
              prettier.enable = true;
              zig.enable = true;
            };
          };

          devShells.default = env.mkShell {
            # Inherit all of the pre-commit and treefmt hooks.
            inputsFrom = [
              config.pre-commit.devShell
              config.treefmt.build.devShell
            ];
            packages = config.pre-commit.settings.enabledPackages ++ [
              env.zig2nix # `zon2json`, `zon2json-lock`, `zon2nix`
            ];
          };
        };
    };
}
