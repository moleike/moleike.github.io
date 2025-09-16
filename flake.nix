{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    treefmt-nix,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};

        bearblog = pkgs.fetchFromGitHub {
          owner = "janraasch";
          repo = "hugo-bearblog";
          rev = "939a4e9e00e18d07ac8e3ba3f314c4e4b9e9f0ba";
          hash = "sha256-VyWYk06HVJ7E6Io+80mO6qK9U0gRdwUQ8btZ6hBT/Wg=";
        };

        yarnOfflineCache = pkgs.fetchYarnDeps {
          yarnLock = ./yarn.lock;
          hash = "sha256-q33qdTf3G62TF1KyBkLAU6hG9Ga6/xbefZ2eLkjl3Zw=";
        };

        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

        blog = pkgs.stdenv.mkDerivation {
          name = "blog";

          nativeBuildInputs = with pkgs; [
            nodejs_22
            yarn
            fixup-yarn-lock
            cacert
            hugo
          ];

          # Exclude themes and public folder from build sources
          src =
            builtins.filterSource
            (path: type:
              !(type
                == "directory"
                && (baseNameOf path
                  == "themes"
                  || baseNameOf path == "public")))
            ./.;

          configurePhase = ''
            export HOME=$(mktemp -d)
          '';

          buildPhase = ''
            yarn config --offline set yarn-offline-mirror ${yarnOfflineCache}
            fixup-yarn-lock yarn.lock

            yarn install --offline \
              --frozen-lockfile \
              --ignore-platform \
              --ignore-scripts \
              --no-progress \
              --non-interactive

            mkdir -p themes
            ln -s ${bearblog} ./themes/hugo-bearblog

            hugo --config ./hugo.toml --minify
          '';
          installPhase = ''
            cp -r public $out
          '';
          meta = with pkgs.lib; {
            description = "Alex Moreno's blog";
            platforms = platforms.all;
          };
        };
      in {
        packages = {
          blog = blog;
          default = blog;
        };

        apps.default = flake-utils.lib.mkApp {
          drv = pkgs.writeShellScriptBin "hugo" ''
            cat << EOF >> .yarnrc
                yarn-offline-mirror "${yarnOfflineCache}"
            EOF
            ${pkgs.yarn}/bin/yarn install --offline \
              --frozen-lockfile \
              --ignore-platform \
              --ignore-scripts \
              --no-progress \
              --non-interactive
            ${pkgs.hugo}/bin/hugo server --config ./hugo.toml --watch;
          '';
        };

        # for `nix fmt`
        formatter = treefmtEval.config.build.wrapper;
      }
    );
}
