#!/usr/bin/env bash
# Glue the two halves of the frq Android app into an APK.
#
#   libvidya.so    the C ABI on Rust/egui, cross-compiled by buck2, and the
#                  NativeActivity's own library (it holds android-activity's
#                  glue, so it owns the event loop)
#   libjoltapp.so  vidya's android/jolt_main.c plus frq's Jolt boot image,
#                  dlopened by the above
#
# Neither half is built here beyond that last link: the UI library comes from
# vidya's `just ffi-android` and the boot image from build-jolt-boot.sh. Both
# native pieces are vidya's — only the boot image is frq's.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VIDYA="${VIDYA:-$(cd "$ROOT/../vidya" && pwd)}"
ANDROID_HOME="${ANDROID_HOME:-$HOME/.local/share/android-sdk}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/.local/share/android-ndk-r29}"
CHEZ_ANDROID="${CHEZ_ANDROID:-$HOME/.cache/vidya-chez-android}"
BUILD="$ROOT/android/build"
JOLT_BUILD="$BUILD/jolt"
STAGE="$BUILD/stage"
TOOLS="$ANDROID_HOME/build-tools/36.0.0"
ADB="${ADB:-$ANDROID_HOME/platform-tools/adb}"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
PACKAGE="uk.nandi.frq"
ACTIVITY="$PACKAGE/android.app.NativeActivity"
API=28

for path in \
  "$NDK_BIN/aarch64-linux-android$API-clang" \
  "$ANDROID_HOME/platforms/android-36/android.jar" \
  "$TOOLS/aapt2" "$TOOLS/zipalign" "$TOOLS/apksigner"; do
  [[ -e "$path" ]] || { echo "missing Android tool: $path" >&2; exit 1; }
done

# --- the UI half ------------------------------------------------------------
( cd "$VIDYA" && just ffi-android >&2 )
VIDYA_SO="$VIDYA/build/android/arm64-v8a/libvidya.so"
[[ -f "$VIDYA_SO" ]] || { echo "missing $VIDYA_SO" >&2; exit 1; }

# --- the Jolt half ----------------------------------------------------------
"$ROOT/android/build-jolt-boot.sh" "$JOLT_BUILD"
(
  cd "$JOLT_BUILD"
  # The boot image travels as a blob in the object file's data section; the
  # _binary_jolt_boot_{start,end} symbols jolt_main.c reads come from this.
  "$NDK_BIN/llvm-objcopy" \
    --input-target=binary \
    --output-target=elf64-littleaarch64 \
    --binary-architecture=aarch64 \
    jolt.boot jolt_boot.o
)

rm -rf "$STAGE"
mkdir -p "$STAGE/lib/arm64-v8a"
cp "$VIDYA_SO" "$STAGE/lib/arm64-v8a/libvidya.so"

"$NDK_BIN/aarch64-linux-android$API-clang" \
  -shared -fPIC -O2 \
  -o "$STAGE/lib/arm64-v8a/libjoltapp.so" \
  "$VIDYA/android/jolt_main.c" \
  "$JOLT_BUILD/jolt_boot.o" \
  -I"$JOLT_BUILD" \
  -I"$VIDYA/raylib/include" \
  -I"$VIDYA/ffi/include" \
  -L"$STAGE/lib/arm64-v8a" \
  "$CHEZ_ANDROID/tarm64le/boot/tarm64le/libkernel.a" \
  "$CHEZ_ANDROID/lz4/lib/liblz4.a" \
  -lvidya -landroid -llog -lz -ldl -lm \
  -Wl,--no-undefined

# --- the APK ----------------------------------------------------------------
UNALIGNED="$BUILD/frq-unaligned.apk"
ALIGNED="$BUILD/frq-aligned.apk"
APK="$BUILD/frq.apk"
rm -f "$UNALIGNED" "$ALIGNED" "$APK"
"$TOOLS/aapt2" link \
  -o "$UNALIGNED" \
  -I "$ANDROID_HOME/platforms/android-36/android.jar" \
  --manifest "$ROOT/android/AndroidManifest.xml" \
  --min-sdk-version $API \
  --target-sdk-version 36 \
  --version-code 1 \
  --version-name 0.1.0
# Stored, not deflated: the loader maps these straight out of the APK.
(cd "$STAGE" && zip -q -0 "$UNALIGNED" \
  lib/arm64-v8a/libvidya.so lib/arm64-v8a/libjoltapp.so)
"$TOOLS/zipalign" -f -p 4 "$UNALIGNED" "$ALIGNED"

KEYSTORE="$HOME/.android/debug.keystore"
if [[ ! -f "$KEYSTORE" ]]; then
  mkdir -p "$(dirname "$KEYSTORE")"
  keytool -genkeypair -v \
    -keystore "$KEYSTORE" -storepass android -keypass android \
    -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
    -dname "CN=Android Debug,O=Android,C=US"
fi
"$TOOLS/apksigner" sign \
  --ks "$KEYSTORE" --ks-key-alias androiddebugkey \
  --ks-pass pass:android --key-pass pass:android \
  --out "$APK" "$ALIGNED"
"$TOOLS/apksigner" verify "$APK" >/dev/null

case "${1:-build}" in
  build)   printf '%s\n' "$APK" ;;
  install) "$ADB" install -r "$APK" ;;
  run)
    "$ADB" install -r "$APK"
    "$ADB" shell am force-stop "$PACKAGE"
    "$ADB" shell am start -n "$ACTIVITY"
    ;;
  log)     "$ADB" logcat -s VidyaJolt Vidya ;;
  *)
    echo "usage: $0 [build|install|run|log]" >&2
    exit 2
    ;;
esac
