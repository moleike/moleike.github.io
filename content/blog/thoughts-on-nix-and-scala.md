---
title: "Some thoughts on packaging apps with Nix"
date: 2025-08-30
description: "Some thoughts on building apps with Nix"
draft: true
tags:
  - nix
  - scala
  - docker
---

Nix is slowly taking root across different layers of my development needs:
devshells for per-project development environments (with flakes and direnv),
home-manager for dotfiles and nix-darwin for system-level configuration of
MacOS. This blog, too, is build and deployed with Nix:

```nix
buildPhase = ''
  mkdir -p themes
  ln -s ${bearblog} ./themes/hugo-bearblog
  ${pkgs.hugo}/bin/hugo --config ./hugo.toml --minify
'';
installPhase = ''
  cp -r public $out
'';
```

Which incidentally documents how to run this blog, which I would otherwise
forget. Devshells are my favorite feature: declarative, isolated, and
reproducible development environment that provides all the necessary
dependencies for a project, and together with direnv, it makes for a pretty
seamless experience---and all that without altering the host system.

But recently I started to see value too on packaging applications, and
containerizing them (more on that later). That sounded absurd to state, since
Nix is a package manager, so if something you should be able to do is to build
software. Nixpkgs, the official Nix package respository, is to date the largest
and most up to date package repository according to https://repology.org/.
