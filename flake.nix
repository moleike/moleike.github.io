{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-24.11";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";

    bearblog = {
      url = github:janraasch/hugo-bearblog/939a4e9e00e18d07ac8e3ba3f314c4e4b9e9f0ba;
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    treefmt-nix,
    bearblog,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};

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

          buildPhase = ''
            cat << EOF >> .yarnrc
                yarn-offline-mirror "${yarnOfflineCache}"
            EOF
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
