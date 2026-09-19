#!/usr/bin/env bash
# The cosmic desktop build's toolchain: a jolt binary, the native objects, and
# the two Jolt libraries the launcher hands to `-Sdeps`. Each pinned, fetched
# into a directory, and that is the whole of it. No nix.
#
# This is `tools/toolchain.sh` for the other target. That one fetches a
# Flutter, a JDK and a Clojure CLI because the web build is a compiler run;
# this one fetches a runtime and its libraries because the cosmic build is not
# a compilation at all — jolt reads source at startup, so "building" frq for
# the desktop means putting the right files next to each other.
#
# What made this possible is that every piece is now published as something a
# machine without nix can use:
#
#   jolt          one binary, chez linked in statically. Stock /lib64
#                 interpreter, NEEDED libc and libm and nothing else.
#   jolt-native   the `portable` tarball — the backends with their NEEDED
#                 closure beside them and RUNPATH $ORIGIN. The plain
#                 x86_64-linux tarball is NOT this: those objects resolve
#                 through the builder's /nix/store and are for nix consumers.
#   libmoq_ffi    an upstream release object, no RUNPATH, needs libgcc_s.
#   glimmer       Jolt source. Read, not linked.
#
# What is NOT here, and has to be on the machine that RUNS the result: the GL
# driver, and glibc. That is deliberate and it is what replaces the AppImage —
# nix-appimage carried a Mesa, which is why the launcher needed a nixGL to put
# the host's driver in front of it. Carrying no Mesa needs no nixGL.
#
#   tools/desktop-toolchain.sh                 fetch whatever is missing
#   eval "$(tools/desktop-toolchain.sh env)"   ...and set this shell up
#   tools/desktop-toolchain.sh exec -- jolt --version
#
# `FRQ_DESKTOP_TOOLCHAIN` says where it lives; the default is `.toolchain-
# desktop/` at the top of the checkout, and the container points it at a
# volume so the fetch happens once across runs rather than once across
# containers.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TC="${FRQ_DESKTOP_TOOLCHAIN:-$root/.toolchain-desktop}"

# The pins. A URL and a hash, and nothing resolved at run time — the same rule
# tools/toolchain.sh states and for the same reason.

# The runtime. One binary out of the fork's release, and it really is one
# binary: `patchelf --print-needed` on it says libm and libc.
#
# To move it: tag a release in gitlab.com/nandithebull/jolt and take the URL
# and sha256 from its asset. The version string the binary prints is the tag,
# so a mismatch between this pin and the flake's `jolt-src` rev is visible in
# `jolt --version` rather than silent.
JOLT_VERSION="v0.7.28-1-g2b80d68d"
JOLT_URL="https://gitlab.com/-/project/85910549/uploads/c67e91d30934c404583c004710c249a6/jolt-${JOLT_VERSION}-x86_64-linux.tar.gz"
JOLT_SHA="aabb71f809aebd9d607b7a5036229f933c733ae90785cb29df899f116be9589f"

# The native backends, and the Jolt source that binds them, at ONE revision.
#
# One variable for both on purpose. glimmer-cosmic talks to libjoltcosmic over
# a retained-tree ABI that is not versioned, and the flake's comment on the
# jolt-native input says what drift costs: the Jolt half sent a reaction
# pill's hover card to a backend with no handler for one, and the pill said
# nothing. The source and the object are the same commit here by construction.
JOLT_NATIVE_REV="65c27be020b52eb87d0c0718c8cfff1869e8d2f7"
JOLT_NATIVE_URL="https://gitlab.com/api/v4/projects/85910092/packages/generic/jolt-native/${JOLT_NATIVE_REV}/x86_64-linux-portable.tar.gz"
# Filled in from the first pipeline that publishes this revision's tarball:
#
#   curl -fsSL "$JOLT_NATIVE_URL" | sha256sum
#
# Left as the placeholder deliberately rather than omitted — an unpinned
# fetch of a URL under a package registry that serves the NEWEST upload for a
# given name is exactly the moving target these pins exist to refuse.
JOLT_NATIVE_SHA="${FRQ_JOLT_NATIVE_SHA:-0000000000000000000000000000000000000000000000000000000000000000}"

# MoQ over QUIC behind UniFFI's C ABI, from upstream's release rather than
# built. Same object and same version the flake fetches.
MOQ_FFI_VERSION="0.3.17"
# The triple is the Rust one and not the nix system name -- `x86_64-linux`
# gets a 404 from this URL, which is how that got noticed.
MOQ_FFI_TARGET="x86_64-unknown-linux-gnu"
MOQ_FFI_URL="https://github.com/kixelated/moq/releases/download/moq-ffi-v${MOQ_FFI_VERSION}/moq-ffi-${MOQ_FFI_VERSION}-${MOQ_FFI_TARGET}-libmoq_ffi.so"
MOQ_FFI_SHA="773417a55e0981db43fa0df7597e7514501075f0945e436cc75c4f6e86cf7d42"

# glimmer, at the rev deps.edn pins. Source, so it is cloned rather than
# fetched as an archive: a git rev is immutable in a way a forge's generated
# tarball is not — those are re-compressed across forge versions, and a
# sha256 over one is a pin that breaks without anything having changed.
GLIMMER_REPO="https://gitlab.com/nandithebull/glimmer.git"
GLIMMER_REV="399df371c790d690fb6e4560c3d4d7f838502857"

JOLT_NATIVE_REPO="https://gitlab.com/nandithebull/jolt-native.git"

# What the host still has to bring. Small and boring, but a missing one fails
# further from here with a worse message.
require_host_tools() {
    local missing=()
    for t in curl tar git sha256sum; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "desktop-toolchain: this needs ${missing[*]} on PATH and cannot fetch them" >&2
        exit 1
    fi
}

# One archive, unpacked once. The stamp holds the hash rather than the
# version, and the work happens in `.tmp` so a half-finished unpack is never
# mistaken for a finished one — `tools/toolchain.sh` explains at length.
install_archive() {
    local name=$1 url=$2 sha=$3 strip=$4
    local dest="$TC/$name" stamp="$TC/$name.sha256"
    if [ -d "$dest" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "$sha" ]; then
        return 0
    fi
    echo "desktop-toolchain: fetching $name" >&2
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

# The same, for something that is one file rather than an archive.
install_file() {
    local name=$1 url=$2 sha=$3 into=$4
    local dest="$TC/$name" stamp="$TC/$name.sha256"
    if [ -d "$dest" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "$sha" ]; then
        return 0
    fi
    echo "desktop-toolchain: fetching $name" >&2
    rm -rf "$dest" "$dest.tmp"
    mkdir -p "$dest.tmp/$(dirname "$into")"
    curl -fsSL --retry 3 -o "$dest.tmp/$into" "$url"
    echo "$sha  $dest.tmp/$into" | sha256sum -c - >/dev/null
    mv "$dest.tmp" "$dest"
    echo "$sha" > "$stamp"
}

# Source, by revision. `git -c advice.detachedHead=false` because this is
# always a detached checkout and the advice is four lines of it per fetch.
install_source() {
    local name=$1 repo=$2 rev=$3
    local dest="$TC/$name" stamp="$TC/$name.rev"
    if [ -d "$dest" ] && [ "$(cat "$stamp" 2>/dev/null || true)" = "$rev" ]; then
        return 0
    fi
    echo "desktop-toolchain: cloning $name at ${rev:0:8}" >&2
    rm -rf "$dest" "$dest.tmp"
    # A rev is not a ref, so this is init-fetch rather than clone --branch:
    # `git clone --depth 1` cannot take a sha unless the server allows it, and
    # `fetch --depth 1 <sha>` is the form that works everywhere.
    mkdir -p "$dest.tmp"
    git -C "$dest.tmp" init -q
    git -C "$dest.tmp" remote add origin "$repo"
    git -C "$dest.tmp" fetch -q --depth 1 origin "$rev"
    git -C "$dest.tmp" -c advice.detachedHead=false checkout -q FETCH_HEAD
    mv "$dest.tmp" "$dest"
    echo "$rev" > "$stamp"
}

check_pins() {
    if [ "$JOLT_NATIVE_SHA" = "0000000000000000000000000000000000000000000000000000000000000000" ]; then
        cat >&2 <<MSG
desktop-toolchain: the jolt-native portable tarball is not pinned yet.

  It is published by the first pipeline to run on jolt-native's main at
  ${JOLT_NATIVE_REV:0:8}. Once it exists:

    curl -fsSL "$JOLT_NATIVE_URL" | sha256sum

  and put that in JOLT_NATIVE_SHA here, or pass it for one run as
  FRQ_JOLT_NATIVE_SHA=<sha256>.
MSG
        exit 1
    fi
}

install_all() {
    require_host_tools
    check_pins
    mkdir -p "$TC"
    # strip 1: the jolt tarball is rooted at a versioned directory.
    install_archive jolt "$JOLT_URL" "$JOLT_SHA" 1
    # strip 0: the portable tarball is rooted at lib/ and include/ already,
    # which is the shape a consumer is meant to take it in.
    install_archive jolt-native "$JOLT_NATIVE_URL" "$JOLT_NATIVE_SHA" 0
    install_file moq-ffi "$MOQ_FFI_URL" "$MOQ_FFI_SHA" lib/libmoq_ffi.so
    install_source glimmer "$GLIMMER_REPO" "$GLIMMER_REV"
    install_source jolt-native-src "$JOLT_NATIVE_REPO" "$JOLT_NATIVE_REV"
}

# The environment, as shell.
#
# JOLT_NATIVE_LIB is how jolt resolves every `:jolt/native` name, and it wants
# ONE directory — the objects come from two places (the portable tarball and
# the moq-ffi release), so `tools/build-desktop.sh` stages them into one and
# this names where that landed.
print_env() {
    cat <<ENV
export FRQ_DESKTOP_TOOLCHAIN="$TC"
export JOLT_NATIVE_LIB="$TC/native"
export LD_LIBRARY_PATH="$TC/native\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
export FRQ_GLIMMER="$TC/glimmer"
export FRQ_GLIMMER_COSMIC="$TC/jolt-native-src/glimmer-backends/glimmer-cosmic"
export PATH="$TC/jolt:\$PATH"
ENV
}

case "${1:-install}" in
    install) install_all ;;
    env)     install_all; print_env ;;
    exec)    install_all; eval "$(print_env)"; shift; [ "${1:-}" = "--" ] && shift; exec "$@" ;;
    *)       echo "usage: desktop-toolchain.sh [install|env|exec -- cmd...]" >&2; exit 1 ;;
esac
