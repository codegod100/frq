#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The boot image is built from :paths alone — there is no dependency
# resolution inside a cross compile — so every source root deps.edn would have
# resolved has to be named here instead. Two of them are git dependencies,
# which means the jolt cache rather than a checkout; the shas come out of
# deps.edn so there is one place to bump them.
CHECKOUT="$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")"
if [[ -z "${JOLT_NATIVE:-}" ]]; then
  if [[ -d "$CHECKOUT/../jolt-native" ]]; then
    JOLT_NATIVE="$(cd "$CHECKOUT/../jolt-native" && pwd)"
  else
    JOLT_NATIVE="$CHECKOUT/.jolt-native"
  fi
fi

# The sha deps.edn pins for a given git url, so a bump there reaches this.
dep_sha() {
  awk -v url="$1" '
    index($0, url) { found = 1 }
    found && $1 == ":git/sha" { gsub(/[^0-9a-f]/, "", $2); print $2; exit }
  ' "$ROOT/deps.edn"
}
GLIMMER_SHA="$(dep_sha https://gitlab.com/nandithebull/glimmer)"
GLIMMER="${GLIMMER:-$HOME/.jolt/gitlibs/https___gitlab.com_nandithebull_glimmer/$GLIMMER_SHA/src}"

# glimmer-vidya lives inside jolt-native, so a sibling checkout answers for it
# the way it answers for libvidya; the cache is the fallback, at the sha
# deps.edn pins.
GLIMMER_VIDYA_SHA="$(dep_sha https://gitlab.com/nandithebull/jolt-native)"
if [[ -z "${GLIMMER_VIDYA:-}" ]]; then
  if [[ -d "$JOLT_NATIVE/jolt/glimmer-vidya/src" ]]; then
    GLIMMER_VIDYA="$JOLT_NATIVE/jolt/glimmer-vidya/src"
  else
    GLIMMER_VIDYA="$HOME/.jolt/gitlibs/https___gitlab.com_nandithebull_jolt-native/$GLIMMER_VIDYA_SHA/jolt/glimmer-vidya/src"
  fi
fi

for path in "$GLIMMER" "$GLIMMER_VIDYA"; do
  [[ -d "$path" ]] || {
    echo "missing Jolt source root: $path" >&2
    echo "run \`jolt -M:frq --help\` once to populate the git cache" >&2
    exit 1
  }
done
OUT="${1:?usage: build-jolt-boot.sh OUTPUT_DIRECTORY | --stamp}"
# The DotSlash-pinned jolt, not whatever is on PATH: an upstream jolt cannot
# open a TLS connection on Android — it reads the socket address out of
# `struct addrinfo` at glibc's offset, which is Bionic's `ai_canonname` — so a
# build made with one produces an APK that cannot sign in or send a picture.
# Override with JOLT= to use another.
#
# DOTSLASH and JOLT_MANIFEST are set when buck runs this: the manifest and the
# fetcher are inputs to that action, so the machine running it needs neither
# jolt nor DotSlash installed, and a remote worker resolves the same pin
# against the same digest. Without them the shim beside this script answers,
# which is what a person at a terminal gets.
if [[ -z "${JOLT:-}" ]]; then
  if [[ -n "${DOTSLASH:-}" && -n "${JOLT_MANIFEST:-}" ]]; then
    JOLT="$("$DOTSLASH" -- fetch "$JOLT_MANIFEST")"
  else
    JOLT="$ROOT/scripts/jolt"
  fi
fi
MODULE="${MODULE:-frq.app}"
CHEZ_ANDROID="${CHEZ_ANDROID:-$HOME/.cache/vidya-chez-android}"
HOST_SCHEME="$CHEZ_ANDROID/ta6le/bin/ta6le/scheme"
TARGET_BOOT="$CHEZ_ANDROID/boot/tarm64le"
XPATCH="$CHEZ_ANDROID/xc-tarm64le/s/xpatch"

for path in "$HOST_SCHEME" "$TARGET_BOOT/petite.boot" \
  "$TARGET_BOOT/scheme.boot" "$TARGET_BOOT/scheme.h" "$XPATCH"; do
  [[ -e "$path" ]] || {
    echo "missing Android Chez artifact: $path" >&2
    echo "Build Chez's tarm64le cross target first." >&2
    exit 1
  }
done
[[ -x "$JOLT" ]] || command -v "$JOLT" >/dev/null || {
  echo "Jolt executable not found: $JOLT" >&2
  exit 1
}

# The boot image is a pure function of the Scheme sources, the module name, the
# flat-split flag and Chez's own boot files — all static. Hash them, and skip
# the whole thing when the stamp still matches: a Rust-only APK rebuild has no
# reason to spend fifteen single-threaded seconds recompiling Scheme.
#
# The flag is part of the stamp on purpose. JOLT_NO_FLAT_SPLIT changes the shape
# of what `jolt build` emits, so an app.build/ left by an ordinary build is not
# reusable here; a stamp miss wipes the tree below, which is what the
# unconditional `rm -rf` used to be defending against.
STAMP="$OUT/jolt.boot.stamp"
stamp_now() {
  {
    printf '%s\n' "$MODULE" "JOLT_NO_FLAT_SPLIT=1"
    "$JOLT" --version 2>/dev/null || true
    find "$ROOT/src" "$GLIMMER" "$GLIMMER_VIDYA" -type f \
      \( -name '*.jolt' -o -name '*.edn' \) -print0 | sort -z | xargs -0 sha256sum
    sha256sum "$TARGET_BOOT/petite.boot" "$TARGET_BOOT/scheme.boot" "$XPATCH"
  } | sha256sum | cut -d' ' -f1
}

# buck needs this before the work rather than after: the sources it hashes live
# in the jolt cache and in jolt-native, outside this cell, so nothing else makes
# them reach an action's digest. See the `buck` recipe in the justfile.
if [[ "${1:-}" == "--stamp" ]]; then
  stamp_now
  exit 0
fi

WANT="$(stamp_now)"
if [[ -f "$OUT/jolt.boot" && -f "$OUT/scheme.h" && -f "$STAMP" ]] &&
   [[ "$(<"$STAMP")" == "$WANT" ]]; then
  echo "jolt boot image up to date" >&2
  exit 0
fi

rm -f "$STAMP"
rm -rf "$OUT/project" "$OUT/cross"
mkdir -p "$OUT/project" "$OUT/cross"
cat > "$OUT/project/deps.edn" <<EOF
{:paths ["$ROOT/src" "$GLIMMER" "$GLIMMER_VIDYA"]}
EOF

(
  cd "$OUT/project"
  JOLT_NO_FLAT_SPLIT=1 "$JOLT" build \
    -m "$MODULE" -o app
)

cat > "$OUT/cross/compile.ss" <<EOF
(import (chezscheme))
(load "$XPATCH")
(optimize-level 2)
(generate-inspector-information #f)
(compile-file "$OUT/project/app.build/flat.ss" "$OUT/cross/flat.so")
(make-boot-file "$OUT/jolt.boot" '()
  "$TARGET_BOOT/petite.boot"
  "$TARGET_BOOT/scheme.boot"
  "$OUT/cross/flat.so")
EOF

SCHEMEHEAPDIRS="$CHEZ_ANDROID/ta6le/boot/ta6le" \
  "$HOST_SCHEME" --script "$OUT/cross/compile.ss"

cp "$TARGET_BOOT/scheme.h" "$OUT/scheme.h"

# Last, so an interrupted build leaves no stamp and the next run redoes it.
printf '%s\n' "$WANT" > "$STAMP"
