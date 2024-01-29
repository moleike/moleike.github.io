# treefmt.nix
{pkgs, ...}: {
  projectRootFile = "flake.nix";
  programs.alejandra.enable = true;
  programs.prettier.enable = true;
}
