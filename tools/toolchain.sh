#!/usr/bin/env bash
# The toolchain the build needs, fetched by hand.
#
# One archive — Nim — pinned by version and by sha256, unpacked into
# `.toolchain/`, and put on a PATH. That is the whole of it. No nix, no image,
# no devShell: a checkout plus this script is a machine that can build any
# target here, and the same script is what the Modal containers run.
#
# It used to fetch Flutter too, which carried Dart, and before that a JDK,
# the Clojure CLI and an Android SDK. The app is Nim from the state to the
# pixels now — nimkit paints it, on GTK and in a page — so Nim is all of it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="${FRQ_TOOLCHAIN:-$root/.toolchain}"

# The pins. A version and its hash, and nothing derived at run time: a
# toolchain that resolves "latest" is a toolchain that changes under you
# between two builds of the same commit.
#
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
# in every base image that is not deliberately empty — but a missing one fails
# somewhere far from here with a much worse message than this.
require_host_tools() {
    local missing=()
    for t in curl tar cc; do
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

install_all() {
    require_host_tools
    mkdir -p "$TC"
    install_archive nim "$NIM_URL" "$NIM_SHA" 1
}

# The environment, as shell: the toolchain's own directory, and Nim on PATH.
print_env() {
    cat <<ENV
export FRQ_TOOLCHAIN="$TC"
export PATH="$TC/nim/bin:\$PATH"
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
        echo "nim     $NIM_VERSION"
        ;;
    *) echo "usage: toolchain.sh [install|env|exec -- cmd...|versions]" >&2; exit 1 ;;
esac
