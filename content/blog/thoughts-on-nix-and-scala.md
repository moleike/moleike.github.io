---
title: "Package and deploy Scala programs with Nix and Docker"
date: 2025-08-30
description: "Some thoughts on building apps with Nix"
tags:
  - nix
  - scala
  - docker
---

[Nix] is slowly taking root across different layers of my development stack. Up
until recently, I used Nix primarily for:
- trying new tools without headaches with `nix-shell`
- reproducible development environments (with [flakes] and [direnv])
- maintaining declarative dotfiles with [home-manager] and
- having a reliable MacOS configuration with [nix-darwin]

All of these uses have one thing in common: a purely functional package manager,
that treats packages _as values_, where packages are never overwritten and
upgrades are done atomically---you can always rollback to a previous state.

Nix has worked reasonably well for my configuration needs, so in this post I
will briefly explore building a fully-reproducible Scala app with Nix, and how
to deal with dependencies that are not managed by Nix. Finally we'll see how
easy is to containerize our app with a very minimal Dockerfile.

> Note that there are several blog posts talking about Nix with Docker, see for
> example [here](https://numtide.com/blog/nix-docker-or-both/) or
> [here](https://mitchellh.com/writing/nix-with-dockerfiles). What I am about to
> share is my perspective on Scala, but still, most of what I'll say is language
> agonstic.

Before jumping on building with Nix, let me first briefly brush up on some
concepts.

## Derivations

To build packages with Nix you define a _derivation_. They are _pure_ functions,
so the same input generate the same output: a unique path within the Nix
store---which acts as the ground truth for all packages.

From these derivations we piece together _build closures_: derivations together
with its direct and transitive dependencies, forming a self-contained set of
files in the Nix store.

The built-in way to define a derivation in nix is with `stdenv.mkDerivation`.
However, this assumes an Autotools-based build of your application, and so
commonly there are specialized functions in Nixpkgs for many languages and build
systems, documented
[here](https://nixos.org/manual/nixpkgs/stable/#chap-language-support).

Note that builds in Nix are sandboxed, and for good reasons: we want to ensure
hermeticity and reproducibility---that's why derivations are pure and among
other things can't access the network. But then, how do we fetch data not
available in the inputs e.g. download packages from a Maven repository while
resolving dependencies? There are different approaches to get round this, but
Nix provides _fixed-output_ derivation for this purpose.

### Fixed-output derivations

These are derivations where the outputs are independent of its inputs and the
content hash of the output is known and provided in advance. These derivations
can then access the network, download the required external dependencies and
since a cryptographic hash was provided in advance, Nix then computes a hash
from the generated output and checks for integrity, maintaining reproducibility
of the downloaded dependencies and build.

When building for the first time you just let the build fail: Nix prints out the
hash that was expected, which then you can add to the derivation ---a strategy
known as _trust on first use_ (TOFU).

### sbt-derivation

Fortunately there is a derivation for building Scala projects, so we do not need
to create one ourselves. The way this works is by creating two separate Nix derivations: 
- one for project dependencies---with a fixed output hash, as we mentioned
  earlier, to guarantee reproducibility
- another one for the actual build process, with the project dependencies
  available in the workspace
  
Note that [sbt-derivation] is not upstreamed to nixpkgs, so we need an overlay to
add it to the set of packages.

## An example with Nix flakes

Now it's time to show some code. I put up an example sbt project with Nix flakes
on this [repo](https://github.com/moleike/hello-nix-scala). Much of the code is borrowed
from Zero to Nix [here](https://zero-to-nix.com/start/nix-build/)---which by the
way is what got me started with this.

```nix
sbt.mkSbtDerivation {
  pname = name;
  version = version;
  depsSha256 = "";
  src = ./.;
  depsWarmupCommand = ''
    sbt 'managedClasspath; compilers'
  '';
  startScript = ''
    #!${pkgs.runtimeShell}

    exec ${jre}/bin/java \
      ''${JAVA_OPTS:-} \
      -cp \
      "${placeholder "out"}/share/${name}/lib/*" \
      ${nixpkgs.lib.escapeShellArg mainClass} \
      "$@"
  '';
  buildPhase = ''
    sbt stage
  '';
  installPhase = ''
    mkdir -p $out/share/${name}/lib
    cp target/universal/stage/lib/*.jar $_
    install -T -D -m755 $startScriptPath $out/bin/${name}
  '';
  passAsFile = [ "startScript" ];
};
```
  
  


[Nix]: https://nixos.org/
[flakes]: https://zero-to-nix.com/concepts/flakes/
[direnv]: https://direnv.net/
[home-manager]: https://github.com/nix-community/home-manager
[nix-darwin]: https://github.com/nix-darwin/nix-darwin
[sbt-derivation]: https://github.com/zaninime/sbt-derivation

[^1]: Binary caches are heavily used to speed up build times
