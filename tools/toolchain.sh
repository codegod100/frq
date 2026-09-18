#!/usr/bin/env bash
# The toolchain the web build needs, fetched by hand.
#
# Three tarballs — Flutter (which carries Dart), a JDK, and the Clojure CLI —
# pinned by version and by sha256, unpacked into `.toolchain/`, and put on a
# PATH. That is the whole of it. No nix, no image, no devShell: a checkout
# plus this script is a machine that can build the web bundle, and the same
# script is what the Modal container runs.
#
# Why not DotSlash, which the rest of the repo uses for its native libraries:
# DotSlash hands out an *immutable* cached artifact, and Flutter is not one.
# `flutter build web` downloads its engine artifacts into `bin/cache/` inside
# its own SDK directory the first time it runs, so the SDK has to be writable
# — which is the same thing `just apk` learned when it had to copy the
# store's Android SDK out to `flutter/.home` before Gradle would touch it.
# A pinned URL and a checked hash give the reproducibility DotSlash is for;
# the writability is what it cannot give.
#
#   tools/toolchain.sh              fetch whatever is missing
#   eval "$(tools/toolchain.sh env)"    ...and put it on this shell's PATH
#   tools/toolchain.sh exec -- flutter --version
#
# `FRQ_TOOLCHAIN` says where it all lives; the default is `.toolchain/` at
# the top of the checkout, and the container points it at a volume so the
# fetch happens once across runs rather than once across containers.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="${FRQ_TOOLCHAIN:-$root/.toolchain}"

# The pins. A version and its hash, and nothing derived at run time: a
# toolchain that resolves "latest" is a toolchain that changes under you
# between two builds of the same commit.
#
# Flutter 3.47.0 is the version this tree was building with under nix, and
# its Dart 3.13.0 is what `flutter/pubspec.yaml` asks for with `sdk: ^3.13.0`.
# To move it: take `version`, `archive` and `sha256` from
# https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json
FLUTTER_VERSION="3.47.0"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_SHA="26cd99d3d94b1367e6b50535a18aeef0282c10a535bbe3ec493534dcdab75296"

# Temurin 17, because `clojure` is a JVM program and ClojureDart's compiler
# runs there. Nothing else in this build wants a JVM.
JDK_VERSION="17.0.20.1+1"
JDK_URL="https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.20.1%2B1/OpenJDK17U-jdk_x64_linux_hotspot_17.0.20.1_1.tar.gz"
JDK_SHA="3808d1d15e3ec6bd5b84057fb5d84c33d8a1536a258146bcea2e603fc726e08e"

# The Clojure CLI, which is a pair of shell scripts and a jar. Upstream ships
# an installer; `install_clojure` below is the four lines of it that matter.
CLOJURE_VERSION="1.12.6.1673"
CLOJURE_URL="https://github.com/clojure/brew-install/releases/download/${CLOJURE_VERSION}/clojure-tools-${CLOJURE_VERSION}.tar.gz"
CLOJURE_SHA="fe9194858e75d5af13c2e2aff92d710674d5bc5105f2b42f90a7d94d82ec023c"

# What the host still has to bring. Small, boring, and on every machine and
# in every base image that is not deliberately empty — but Flutter shells out
# to `git` on its own SDK and to `unzip` on its downloads, so a missing one
# fails somewhere far from here with a much worse message than this.
require_host_tools() {
    local missing=()
    for t in curl tar git unzip; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "toolchain: this needs ${missing[*]} on PATH and cannot fetch them" >&2
        exit 1
    fi
}

# One archive, unpacked once. The stamp holds the hash rather than the
# version, so re-pointing a pin at the same version with different bytes also
# refetches, and a half-finished unpack is never mistaken for a finished one:
# the work happens in `.tmp` and the `mv` at the end is what publishes it.
install_archive() {
    local name=$1 url=$2 sha=$3 strip=$4
    local dest="$TC/$name" stamp="$TC/$name.sha256"
    if [ -d "$dest" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "$sha" ]; then
        return 0
    fi
    echo "toolchain: fetching $name" >&2
    local dl="$TC/.download.$name"
    rm -rf "$dest" "$dest.tmp" "$dl"
    mkdir -p "$dest.tmp"
    curl -fsSL --retry 3 -o "$dl" "$url"
    echo "$sha  $dl" | sha256sum -c - >/dev/null
    tar -xf "$dl" -C "$dest.tmp" --strip-components="$strip"
    rm -f "$dl"
    mv "$dest.tmp" "$dest"
    echo "$sha" > "$stamp"
}

# Upstream's install.sh, minus the ruby. The scripts ship with `PREFIX` and
# `BINDIR` written into them literally and an installer that substitutes the
# directory it is installing to; this is that, done where the tarball landed.
install_clojure() {
    local dest="$TC/clojure"
    [ -x "$dest/bin/clojure" ] && return 0
    mkdir -p "$dest/libexec" "$dest/bin"
    cp "$dest"/*.jar "$dest/libexec/"
    sed "s|PREFIX|$dest|g" "$dest/clojure" > "$dest/bin/clojure"
    sed "s|BINDIR|$dest/bin|g" "$dest/clj" > "$dest/bin/clj"
    chmod +x "$dest/bin/clojure" "$dest/bin/clj"
}

install_all() {
    require_host_tools
    mkdir -p "$TC"
    install_archive flutter "$FLUTTER_URL" "$FLUTTER_SHA" 1
    install_archive jdk "$JDK_URL" "$JDK_SHA" 1
    install_archive clojure "$CLOJURE_URL" "$CLOJURE_SHA" 1
    install_clojure
}

# The environment, as shell. Everything that would otherwise land in a home
# directory is named here and kept inside the toolchain instead: the pub
# cache, the git dependencies tools.deps clones, the local maven repo. One
# directory to keep on a volume, one directory to delete when it goes wrong.
#
# GITLIBS and the maven repo are set for the reason `just apk` sets them —
# the JVM reads user.home out of /etc/passwd, so neither of them follows HOME.
print_env() {
    cat <<ENV
export FRQ_TOOLCHAIN="$TC"
# Flutter's SDK tarball is a git checkout, and the tool shells out to git
# against it for its version -- which fails with "detected dubious ownership"
# whenever the files' owner is not the user running the build. That is the
# normal case on a Modal volume, and the failure is not a warning: the dart
# process ClojureDart's live analyzer talks to dies with it, and the compile
# ends at 'EOF while reading' with nothing about git in the message.
#
# Said through the environment rather than 'git config --global', so it
# travels with this shell and writes nothing into anyone's ~/.gitconfig.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0="$TC/flutter"
export JAVA_HOME="$TC/jdk"
export PUB_CACHE="$TC/pub-cache"
export GITLIBS="$TC/gitlibs"
export FRQ_M2="$TC/m2"
export PATH="$TC/flutter/bin:$TC/jdk/bin:$TC/clojure/bin:\$PATH"
ENV
}

case "${1:-install}" in
    install) install_all ;;
    env)     install_all; print_env ;;
    exec)
        install_all
        shift
        [ "${1:-}" = "--" ] && shift
        eval "$(print_env)"
        exec "$@"
        ;;
    versions)
        echo "flutter $FLUTTER_VERSION"
        echo "jdk     $JDK_VERSION"
        echo "clojure $CLOJURE_VERSION"
        ;;
    *) echo "usage: toolchain.sh [install|env|exec -- cmd...|versions]" >&2; exit 1 ;;
esac
