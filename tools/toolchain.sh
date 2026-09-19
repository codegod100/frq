#!/usr/bin/env bash
# The toolchain the web build needs, fetched by hand.
#
# Archives — Flutter (which carries Dart) and Nim —
# pinned by version and by sha256, unpacked into `.toolchain/`, and put on a
# PATH. That is the whole of it. No nix, no image, no devShell: a checkout
# plus this script is a machine that can build any target here, and the same
# script is what the Modal containers run.
#
# The Android SDK is the one thing not fetched by default, because only
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


# Nim, for `nim/` — the portable core. Upstream's prebuilt linux_x64 tarball,
# so there is no bootstrap compile here. The core deliberately has no
# dependencies outside Nim's standard library, so the compiler is all of it.
#
# Two things Nim wants from the host rather than from here: a C compiler,
# because `nim c` shells out to one, and OpenSSL, because `-d:ssl` in
# nim/nim.cfg makes std/net resolve -lssl and -lcrypto through dynlib at run
# time. A missing libssl is a SIGSEGV in `newContext` that says nothing about
# SSL, which is why require_host_tools checks for cc up front.
NIM_VERSION="2.2.4"
NIM_URL="https://nim-lang.org/download/nim-${NIM_VERSION}-linux_x64.tar.xz"
NIM_SHA="791802138aaf19c8579232c50b4998ce2ae2928b791127ce5b4ef3c7af53fb46"


# What the host still has to bring. Small, boring, and on every machine and
# in every base image that is not deliberately empty — but Flutter shells out
# to `git` on its own SDK and to `unzip` on its downloads, so a missing one
# fails somewhere far from here with a much worse message than this.
require_host_tools() {
    local missing=()
    for t in curl tar git unzip cc; do
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

# The Android SDK, which is a zip rather than a tarball and has to land in a
# layout sdkmanager recognises: cmdline-tools/latest/, with the tools' own
# top-level directory renamed. Everything after that — platform-tools, the
# platform, the build-tools — Gradle asks sdkmanager for as it goes, which is
# why this directory is ours and writable rather than a read-only artifact.
#

install_all() {
    require_host_tools
    mkdir -p "$TC"
    install_archive flutter "$FLUTTER_URL" "$FLUTTER_SHA" 1
    install_archive nim "$NIM_URL" "$NIM_SHA" 1
}

# The environment, as shell. What would otherwise land in a home directory is
# named here and kept inside the toolchain instead — one directory to keep on
# a volume, one directory to delete when it goes wrong.
#
# It used to carry a JDK, the Clojure CLI, a maven repo, a gitlibs cache and
# an Android SDK. All of those were ClojureDart's or the APK's, and both are
# gone: the toolchain is a Flutter and a Nim now.
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
export PUB_CACHE="$TC/pub-cache"
export PATH="$TC/flutter/bin:$TC/nim/bin:\$PATH"
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
        echo "nim     $NIM_VERSION"
        ;;
    *) echo "usage: toolchain.sh [install|env|exec -- cmd...|versions]" >&2; exit 1 ;;
esac
