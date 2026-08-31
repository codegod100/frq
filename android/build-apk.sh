#!/usr/bin/env bash
# Glue the two halves of the frq Android app into an APK.
#
#   libvidya.so    the C ABI on Rust/egui, cross-compiled by buck2, and the
#                  NativeActivity's own library (it holds android-activity's
#                  glue, so it owns the event loop)
#   libjoltapp.so  jolt-native's android/jolt_main.c plus frq's Jolt boot
#                  image, dlopened by the above
#   classes.dex    one Java class, and only because a picture chooser answers
#                  through onActivityResult and a NativeActivity has nowhere to
#                  deliver that
#   libssl.so      OpenSSL, because the platform's own is not ours to load: an
#   libcrypto.so   app's linker namespace refuses /system/lib64/libssl.so, and
#                  without one there is no TLS at all on the phone
#
# Neither half is built here beyond that last link: the UI library comes from
# jolt-native's `just ffi-android` and the boot image from build-jolt-boot.sh.
# Both native pieces are jolt-native's — only the boot image is frq's.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Where jolt-native is, answered the same way the justfile answers it: a
# sibling checkout wins, and otherwise it is the clone `just lib` leaves under
# .jolt-native. --git-common-dir rather than the working tree because this
# script runs from a worktree as readily as from the checkout, and in one of
# those "../jolt-native" is not a sibling of anything.
CHECKOUT="$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir)")"
if [[ -z "${JOLT_NATIVE:-}" ]]; then
  if [[ -d "$CHECKOUT/../jolt-native" ]]; then
    JOLT_NATIVE="$(cd "$CHECKOUT/../jolt-native" && pwd)"
  else
    JOLT_NATIVE="$CHECKOUT/.jolt-native"
  fi
fi
[[ -d "$JOLT_NATIVE" ]] || {
  echo "no jolt-native at $JOLT_NATIVE — run \`just lib\` to clone it" >&2
  exit 1
}
ANDROID_HOME="${ANDROID_HOME:-$HOME/.local/share/android-sdk}"
ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$HOME/.local/share/android-ndk-r29}"
CHEZ_ANDROID="${CHEZ_ANDROID:-$HOME/.cache/vidya-chez-android}"
OPENSSL_ANDROID="${OPENSSL_ANDROID:-$HOME/.cache/frq-openssl-android/lib}"
BUILD="$ROOT/android/build"
JOLT_BUILD="$BUILD/jolt"
STAGE="$BUILD/stage"
TOOLS="$ANDROID_HOME/build-tools/36.0.0"
ADB="${ADB:-$ANDROID_HOME/platform-tools/adb}"
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
PACKAGE="uk.nandi.frq"
ACTIVITY="$PACKAGE/.FrqActivity"
API=28

for path in \
  "$NDK_BIN/aarch64-linux-android$API-clang" \
  "$ANDROID_HOME/platforms/android-36/android.jar" \
  "$TOOLS/aapt2" "$TOOLS/zipalign" "$TOOLS/apksigner" "$TOOLS/d8" \
  "$OPENSSL_ANDROID/libssl.so" "$OPENSSL_ANDROID/libcrypto.so"; do
  [[ -e "$path" ]] || { echo "missing Android tool: $path" >&2; exit 1; }
done

# --- the UI half ------------------------------------------------------------
# buck2 fetches its own NDK for this, from the pin in jolt-native's
# scripts/android-ndk.dotslash, so the toolchain below is the only one that has
# to be installed by hand.
( cd "$JOLT_NATIVE" && just ffi-android >&2 )
VIDYA_SO="$JOLT_NATIVE/build/android/arm64-v8a/libvidya.so"
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

# --- the Java half ----------------------------------------------------------
# One class: the photo chooser's result has to land somewhere, and native code
# is not somewhere. d8 turns it into the classes.dex the runtime loads.
JAVA_BUILD="$BUILD/java"
rm -rf "$JAVA_BUILD"
mkdir -p "$JAVA_BUILD/classes"
# android.jar on the class path is where every android.* type comes from; the
# JDK's own java.* is what is left, and this class uses nothing of it that
# Android does not have. (`-bootclasspath` would be the stricter way to say
# that, and javac refuses it for a release this recent.)
javac --release 17 \
  --class-path "$ANDROID_HOME/platforms/android-36/android.jar" \
  -d "$JAVA_BUILD/classes" \
  "$ROOT/android/java/uk/nandi/frq/FrqActivity.java"
"$TOOLS/d8" --min-api $API --output "$JAVA_BUILD" \
  $(find "$JAVA_BUILD/classes" -name '*.class')

rm -rf "$STAGE"
mkdir -p "$STAGE/lib/arm64-v8a"
cp "$JAVA_BUILD/classes.dex" "$STAGE/classes.dex"
cp "$VIDYA_SO" "$STAGE/lib/arm64-v8a/libvidya.so"
# jolt.mvn-http dlopens these by name at first use; beside the app's own
# libraries is where an app's namespace will answer for that name.
cp "$OPENSSL_ANDROID/libssl.so" "$OPENSSL_ANDROID/libcrypto.so" \
  "$STAGE/lib/arm64-v8a/"

"$NDK_BIN/aarch64-linux-android$API-clang" \
  -shared -fPIC -O2 \
  -o "$STAGE/lib/arm64-v8a/libjoltapp.so" \
  "$JOLT_NATIVE/android/jolt_main.c" \
  "$JOLT_BUILD/jolt_boot.o" \
  -I"$JOLT_BUILD" \
  -I"$JOLT_NATIVE/crates/jolt-vidya/include" \
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
  lib/arm64-v8a/libvidya.so lib/arm64-v8a/libjoltapp.so \
  lib/arm64-v8a/libssl.so lib/arm64-v8a/libcrypto.so)
# The dex is read by the runtime rather than mapped, so it may as well deflate.
(cd "$STAGE" && zip -q "$UNALIGNED" classes.dex)
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
