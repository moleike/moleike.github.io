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

> I am assuming you the reader are a Scala developer with some basic familiarity
> with Nix, otherwise you'll find a somewhat uneven treatment of topics, however
> I provide pointers for further reading in several places.

Before jumping on building with Nix, let me first briefly brush up on some
concepts.

## Derivations

To build packages with Nix you define a _derivation_. They are _pure_ functions,
so the same inputs always generate the same output: a unique path within the Nix
store---which acts as the ground truth for all packages.

From these derivations we piece together _build closures_: derivations together
with its direct and transitive dependencies, forming a self-contained set of
files in the Nix store that determine how to build a package.

The built-in way to define a derivation in nix is with `stdenv.mkDerivation`.

A Nix derivation is executed in a sequence of phases, a little bit like
Autotools employs a three-stage process to build software: configure, make, and
make install. The phases are documented in the manual
[here](https://nixos.org/manual/nixpkgs/stable/#sec-stdenv-phases) and can be
overridden since the default assumes an Autotools-based build, and indeed
Nixpkgs provides specialized derivation functions for several [languages and
build systems][chap-language-support]. Two of these are the `buildPhase` and
`installPhase`. We'll meet them later.

### Fixed-output derivations

Note that builds in Nix are sandboxed, and for good reasons: we want to ensure
hermeticity and reproducibility---that's why derivations are pure and among
other things can't access the network. But then, how do we fetch data not
available in the inputs e.g. download packages from a Maven repository while
resolving dependencies? There are different approaches to get round this, a
common solution is using a _fixed-output_ derivation.

These are derivations where the outputs are independent of its inputs and the
content hash of the output is known and provided in advance---below we show how
to bootstrap this process, by letting the build fail. These derivations can then
access the network, download the required external dependencies and since a
cryptographic hash was provided in advance, Nix then computes a hash from the
generated output and checks for integrity, maintaining reproducibility of the
downloaded dependencies and build.

## A Nix derivation for Scala projects

In order for Nix to build and package an Scala project's dependencies
reproducibly, we need a fixed-output derivation. Fortunately we do not need to
do that ourselves, since there is a project doing just that: [sbt-derivation].
Sbt-derivation internally creates two separate Nix derivations:
- one for project dependencies---with a fixed output hash, as we mentioned
  earlier, to guarantee reproducibility
- another one for the actual build process, with the project dependencies
  available in the workspace
  
Let's see a Nix expression where we call the derivation:


```nix {linenos=false}
let
  repository = fetchTarball "https://github.com/zaninime/sbt-derivation/archive/master.tar.gz";
  overlay = import "${repository}/overlay.nix";
  pkgs = import <nixpkgs> { overlays = [overlay]; };
in
  pkgs.mkSbtDerivation {
    pname = "my-package";
    version = "1.0";
    src = ./.;
    depsSha256 = "";
    # ...
  }
```

Note that [sbt-derivation] is not upstreamed to nixpkgs, so we need an overlay
to add it to the set of packages.

Copy the nix expression above into a file, e.g. `example.nix` and add it to the
root of an sbt project.

Also notice that we pass an empty `depsSha256`. When building for the first
time you just let the build fail: Nix prints out the hash that was expected,
which then you can add to the derivation ---a strategy known as _trust on first
use_ (TOFU):

```zsh
$ nix build -f example.nix
error: hash mismatch in fixed-output derivation '...dependencies.tar.zst.drv':
         specified: sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
            got:    sha256-KZN2wBopyxkW4bWvL88zK5s5TSOD5AKRdBVfD/wIyNs=
```

### What about lockfiles?

Using a hash is a small nuisance since you need to remember to update the
attribute `depsSha256` every time you upgrade dependencies. Some packages, e.g.
`gradle2nix.buildGradlePackage`, `buildRustPackage` or `mkYarnPackage` support
vendoring dependencies directly from a lockfile, but `sbt` does not provide a
built-in lockfile feature.

## Walking through an example

I put up an example sbt project---based on the template at [http4s-io.g8]---with
Nix flakes. The code is on the following repo:
[moleike/hello-nix-scala](https://github.com/moleike/hello-nix-scala).

Sbt has several plugins for creating JARs and executables, below I show two of
the most commons packaging plugins: stb-assembly and sbt-native-packager.

### sbt-assembly

With sbt-assembly we build a fat JAR with app and dependencies together.
The contents of the `flake.nix` are:

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = github:numtide/flake-utils;
    sbt.url = "github:zaninime/sbt-derivation";
    sbt.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sbt, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        name = "hello-nix-scala";
        version = "0.1.0";
        pkgs = import nixpkgs { inherit system; };
      in
      {
        packages.default = sbt.mkSbtDerivation.${system} {
          pname = name;
          inherit version;
          src = ./.;
          depsSha256 = "sha256-xSKC0PRl/8OQwFtxUycNGWenagQOTHW3R5CeUimdZes=";
          buildPhase = ''
            sbt assembly
          '';
          installPhase = ''
            install -T -D -m755 target/scala-3.3.3/${name}.jar $out/bin/${name}
          '';
        };
      }
    );
}
```

As mentioned earlier, the sha256 needs to be updated on a first build, and we
override the derivation build and install phases. The code above relies on
having hardcoded the JAR file name:

```scala
assembly / assemblyJarName := "hello-nix-scala.jar",

```

And also to prepend a launch script to the fat JAR:

```scala
import sbtassembly.AssemblyPlugin.defaultShellScript
ThisBuild / assemblyPrependShellScript := Some(defaultShellScript)
```

Build the package with `nix build`.

After the build, the project's root directory contains a `result` directory,
which is a symbolic link to our new package in the Nix store path:

```sh
$ readlink result
/nix/store/bz975bm40cl865ar8pnbs060slfvcqlr-hello-nix-scala-0.1.0
```

> The result symlink acts as a root for the Nix garbage collector; deleting it
> will make the corresponding store path eligible for garbage collection

Running `nix derivation show` prints the results in the Nix store from
evaluating this package.

To run our HTTP service:

```zsh
$ nix run
warning: Git tree '/Users/amoreno/Playground/hello-nix-scala' is dirty
[io-compute-2] INFO  o.h.e.s.EmberServerBuilderCompanionPlatform - Ember-Server service bound to address: [::]:8080
```

`nix run` simply calls $out/bin/hello-nix-scala.

### sbt-native-packager

In a very similar fashion, we can build our project with sbt-native-packager.
Much of the code that follows is borrowed from the examples at [sbt-derivation].

```nix
{
  inputs = {
    nixpkgs.url = "nixpkgs/nixos-unstable";
    flake-utils.url = github:numtide/flake-utils;
    sbt.url = "github:zaninime/sbt-derivation";
    sbt.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, sbt, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        name = "hello-nix-scala";
        version = "0.1.0";
        mainClass = "io.moleike.hellonixscala.Main";
        pkgs = import nixpkgs {
          inherit system;
        };
      in
      {
        packages.default = sbt.mkSbtDerivation.${system} {
          pname = name;
          inherit version;
          depsSha256 = "sha256-xSKC0PRl/8OQwFtxUycNGWenagQOTHW3R5CeUimdZes=";
          src = ./.;
          startScript = ''
            #!${pkgs.runtimeShell}

            exec ${pkgs.jdk_headless}/bin/java \
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
            libs_dir="$out/share/${name}/lib"
            mkdir -p "$libs_dir"
            cp -ar target/universal/stage/lib/. "$libs_dir"

            install -T -D -m755 $startScriptPath $out/bin/${name}
          '';
          passAsFile = [ "startScript" ];
        };
      }
    );
}
```

In this case, we provide with an explicit launch script. The install phase
copies all the dependencies JARs into _./result/share/hello-nix-scala/lib_ and
the launch script is installed in _./result/bin/hello-nix-scala_.

### Caveats

With defaults, you are building your project twice or even thrice: once for the
dependencies derivation to fetch dependencies and another time for the actual
build of your project, including a possible third time if the deps hash needs
updating. This is because the only direct way to fetch dependencies is by
compiling your project. The attribute `depsWarmupCommand` can be overridden and
there are few workarounds explained in [sbt-derivation] README.

## Docker images with Nix

Nix has support for building Docker images with `pkgs.dockerTools`, without a
Docker daemon, and while going this route you benefit from Nix true
reproducibility, I have found a simple Dockerfile my preferred option,
particularly because of how a Dockerfile allows other team members not familiar
with Nix or your codebase to create, manage, and deploy containers of your
applications.

What I will discuss here is entirely based on this post from Mitchell Hashimoto
[here](https://mitchellh.com/writing/nix-with-dockerfiles).

So the idea behind this approach is to use a [multistage] build, which embodies
the idea of the builder pattern.

On the first stage, the builder, we use Nix as the base image to:
- build our application with `nix build`
- copy the _runtime closure_---the runtime dependencies of our app (bash, jdk,
etc.)---of the output path at result/ to a /tmp directory. This is done via this
command: `nix-store -qR result/` which print out the closure of a store path
- copy the contents of `result/` itself, i.e. our app to a /tmp directory too

On the second stage, we use the [scratch] image, basically an image with no
layers. In this stage with copy from the builder our app into a layer and its
runtime dependencies back to /nix/store and launch the app.

Here is the resulting `Dockerfile`:

```docker
# syntax = docker/dockerfile:1.4
FROM nixos/nix:latest AS builder

WORKDIR /tmp/build
COPY . /tmp/build

RUN mkdir /tmp/nix-store-closure

RUN --mount=type=cache,target=/nix,from=nixos/nix:latest,source=/nix \
    --mount=type=cache,target=/root/.cache <<EOF
  nix \
    --extra-experimental-features "nix-command flakes" \
    --option filter-syscalls false \
    --show-trace \
    --log-format raw \
    build .
  cp -R $(nix-store -qR result/) /tmp/nix-store-closure
  cp -R $(readlink /tmp/build/result) /tmp/result
EOF

FROM scratch

WORKDIR /app

COPY --from=builder /tmp/nix-store-closure /nix/store
COPY --from=builder /tmp/result/ /app/
CMD ["/app/bin/hello-nix-scala"]
```

We added some caching to make builds faster. Let's build and run our Docker image:

```zsh
$ docker build -t hello-nix-scala:test --progress plain .
$ docker run hello-nix-scala:test
[io-compute-6] INFO  o.h.e.s.EmberServerBuilderCompanionPlatform - Ember-Server service bound to address: [::]:8080
```

### Caveats 

What about the image size?

```zsh
$ docker images hello-nix-scala:test --format "{{.Size}}"
658MB
```

That is huge for a hello world! Turns out the default jre package in nixpkgs is
the full JDK. To fix this, we are going to build a JRE with only the modules we
actually need:

```nix {hl_lines=[23, "4-12"]}
outputs = { self, nixpkgs, sbt, flake-utils, ... }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      jre = pkgs.jre_minimal.override {
        modules = [
          "java.base"
          "java.se"
          "java.xml"
          "jdk.unsupported"
        ];
        jdk = pkgs.jdk_headless;
      };
    # ...
    in
    {
      # Package outputs
      packages = {
        default = sbt.mkSbtDerivation.${system} {
          # ...
          startScript = ''
            #!${pkgs.runtimeShell}

            exec ${jre}/bin/java \
              ''${JAVA_OPTS:-} \
              -cp \
              "${placeholder "out"}/share/${name}/lib/*" \
              ${nixpkgs.lib.escapeShellArg mainClass} \
              "$@"
          '';
          # ...
```

```zsh
$ docker images hello-nix-scala:test --format "{{.Size}}"
218MB
```

Before concluding this section, let me mention about an interesting discussion
on Dockerfiles vs. Nix dockerTools in this NixOS Discourse
[topic][dockertools-discussion]. More generally, this
[post](https://numtide.com/blog/nix-docker-or-both/) is a particularly clear
explanation of why would you want to use Nix together with Docker.

[Nix]: https://nixos.org/
[flakes]: https://zero-to-nix.com/concepts/flakes/
[direnv]: https://direnv.net/
[home-manager]: https://github.com/nix-community/home-manager
[nix-darwin]: https://github.com/nix-darwin/nix-darwin
[sbt-derivation]: https://github.com/zaninime/sbt-derivation
[chap-language-support]: https://nixos.org/manual/nixpkgs/stable/#chap-language-support
[http4s-io.g8]: https://github.com/http4s/http4s-io.g8
[dockertools-discussion]: (https://discourse.nixos.org/t/why-would-someone-use-dockertools-buildimage-over-using-a-dockerfile/23025)
[multistage]: https://docs.docker.com/build/building/multi-stage/
[scratch]: https://hub.docker.com/_/scratch

[^1]: Binary caches are heavily used to speed up build times
