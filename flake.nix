{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
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

        treefmtEval = treefmt-nix.lib.evalModule pkgs ./treefmt.nix;

        blog = pkgs.stdenv.mkDerivation {
          name = "blog";
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
          # Link theme to themes folder and build
          buildPhase = ''
            mkdir -p themes
            ln -s ${bearblog} ./themes/hugo-bearblog
            ${pkgs.hugo}/bin/hugo --config ./hugo.toml --minify
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
            mkdir -p themes
            ln -sf ${bearblog} ./themes/hugo-bearblog
            ${pkgs.hugo}/bin/hugo server --config ./hugo.toml --watch;
          '';
        };

        # for `nix fmt`
        formatter = treefmtEval.config.build.wrapper;
      }
    );
}
