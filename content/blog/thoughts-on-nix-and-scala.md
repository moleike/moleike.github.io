---
title: "Some thoughts on packaging apps with Nix"
date: 2025-08-30
description: "Some thoughts on building apps with Nix"
tags:
  - nix
  - scala
  - docker
---

[Nix] is slowly taking root across different layers of my development stack. Up
until recently, I used Nix primarily for reproducible development environments
(with [flakes] and [direnv]), maintaining declarative dotfiles with
[home-manager] and reliable system-level configuration of MacOS with
[nix-darwin], and `nix-shell` for trying new tools without headaches. Honestly, 

All of these uses have one thing in common: a purely functional package manager, that
treats packages as values, where packages are never overwritten, and changes are
atomic---you can always rollback to a previous state.

Nix has worked reasonably well for my configuration needs, so in this post I
will briefly explore building and deploying applications with Nix---Nix is a
source-based package manager and everything is build from scratch[^1].

Before jumping on building with Nix, let me first briefly explain some core concepts.

## Derivations

To build packages with Nix you define a derivation. A derivation is the Nix
language construct for realising a package. They are pure functions, so the same
input generate the same output: a path within the Nix store.

Derivations form build closures: derivations together with its direct and
transitive dependencies, forming a self-contained set of files in the Nix store.

The built-in way to define a derivation in nix is with `stdenv.mkDerivation`.

## Flakes

A flake is the overall structure for managing Nix projects, and it outputs one
or more derivations.

## A first example

For instance, here is a simplified definition of the derivation used to build my
blog:

```nix
blog = pkgs.stdenv.mkDerivation {
  name = "blog";
  src = ./.;
  buildPhase = ''
    mkdir -p themes
    ln -s ${bearblog} ./themes/hugo-bearblog
    ${pkgs.hugo}/bin/hugo --config ./hugo.toml --minify
  '';
  installPhase = ''
    cp -r public $out
  '';
}
```

Both the buildPhase and installPhase are shell scripts to run in the build and install phase, respectively.



[Nix]: https://nixos.org/
[flakes]: https://zero-to-nix.com/concepts/flakes/
[direnv]: https://direnv.net/
[home-manager]: https://github.com/nix-community/home-manager
[nix-darwin]: https://github.com/nix-darwin/nix-darwin

[^1]: Binary caches are commonly used to speed up installation times, in case you
    wonder.
