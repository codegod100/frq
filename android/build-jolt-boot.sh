#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIDYA="${VIDYA:-$(cd "$ROOT/../vidya" && pwd)}"
# glimmer itself is a git dependency, so its sources live in the jolt cache
# rather than in either checkout. The boot image is built from :paths alone —
# there is no dependency resolution inside a cross compile — so the cache path
# has to be named here.
GLIMMER="${GLIMMER:-$HOME/.jolt/gitlibs/https___github.com_jolt-lang_glimmer/5581c331c51aff989259b9e8e92ec920fe5e6741/src}"
OUT="${1:?usage: build-jolt-boot.sh OUTPUT_DIRECTORY}"
JOLT="${JOLT:-$(command -v jolt)}"
MODULE="${MODULE:-frq.app}"
CHEZ_ANDROID="${CHEZ_ANDROID:-$HOME/.cache/vidya-chez-android}"
HOST_SCHEME="$CHEZ_ANDROID/ta6le/bin/ta6le/scheme"
TARGET_BOOT="$CHEZ_ANDROID/boot/tarm64le"
XPATCH="$CHEZ_ANDROID/xc-tarm64le/s/xpatch"

for path in "$HOST_SCHEME" "$TARGET_BOOT/petite.boot" \
  "$TARGET_BOOT/scheme.boot" "$TARGET_BOOT/scheme.h" "$XPATCH"; do
  [[ -e "$path" ]] || {
    echo "missing Android Chez artifact: $path" >&2
    echo "Build Chez's tarm64le cross target first; see ../vidya/android." >&2
    exit 1
  }
done
command -v "$JOLT" >/dev/null || {
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
    find "$ROOT/src" "$VIDYA/glimmer/src" "$GLIMMER" -type f \
      \( -name '*.jolt' -o -name '*.edn' \) -print0 | sort -z | xargs -0 sha256sum
    sha256sum "$TARGET_BOOT/petite.boot" "$TARGET_BOOT/scheme.boot" "$XPATCH"
  } | sha256sum | cut -d' ' -f1
}

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
{:paths ["$ROOT/src" "$VIDYA/glimmer/src" "$GLIMMER"]}
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
