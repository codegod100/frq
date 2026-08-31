set shell := ["bash", "-euo", "pipefail", "-c"]

# Sibling checkouts, found relative to the *main* checkout rather than to this
# directory. In a git worktree they are not the same place: the justfile sits
# at .claude/worktrees/<name>, so "../jolt-native" from here would be
# .claude/worktrees/jolt-native, which is nothing. `--git-common-dir` is the one
# thing that answers the same in a worktree as it does in the checkout it came
# from.
checkout := parent_directory(`git rev-parse --path-format=absolute --git-common-dir`)

# jolt-native holds both shared objects. A sibling checkout wins, so anyone
# working on the two repos together builds what they are editing; everyone else
# gets a clone of the gitlab repo under .jolt-native, pinned to the same commit
# deps.edn takes glimmer-vidya from.
jolt_native_url := "https://gitlab.com/nandithebull/jolt-native.git"
jolt_native_sha := "70072e8e48ad396caeab6f6bd18b999cf449ec8f"
jolt_native := `
    checkout="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
    if [ -d "$checkout/../jolt-native" ]; then
        cd "$checkout/../jolt-native" && pwd
    else
        echo "$checkout/.jolt-native"
    fi
`

default:
    @just --list

# Both native libraries: libvidya (the tree ABI glimmer-vidya binds) and
# libjoltmoq (the AV media plane). One workspace, one target directory.
lib: fetch
    cd {{jolt_native}} && just build

# Clone jolt-native at the pinned commit, unless it is already here — which it
# is whenever the sibling checkout exists, since that is what jolt_native then
# points at.
[private]
fetch:
    if [ ! -d {{quote(jolt_native)}} ]; then \
        git clone {{jolt_native_url}} {{quote(jolt_native)}}; \
        cd {{quote(jolt_native)}} && git checkout --detach {{jolt_native_sha}}; \
    fi

# buck2, with the machine's paths written where the BUCK files can read them.
#
# The same arrangement jolt-native uses, and for the same reason: a BUCK file
# may not look around the machine, and these five answers differ on every one.
# Generated rather than committed, so no checkout carries another's paths.
buck *args:
    #!/usr/bin/env bash
    set -euo pipefail
    android_home="${ANDROID_HOME:-$HOME/.local/share/android-sdk}"
    chez="${CHEZ_ANDROID:-$HOME/.cache/vidya-chez-android}"
    openssl="${OPENSSL_ANDROID:-$HOME/.cache/frq-openssl-android/lib}"
    for path in "$android_home/build-tools/36.0.0/aapt2" \
                "$android_home/platforms/android-36/android.jar" \
                "$chez/boot/tarm64le/scheme.boot" \
                "$openssl/libssl.so"; do
        [[ -e "$path" ]] || { echo "missing: $path" >&2; exit 1; }
    done
    # A jolt-native checkout wins over the pinned release, so that anyone
    # working on both repos at once builds what they are editing. It is staged
    # into this tree because a buck2 cell cannot reach outside its own root,
    # and an action that shelled out to the other project would have nothing to
    # invalidate on. With no checkout the release answers instead, fetched by
    # digest — see toolchains/dist and scripts/libvidya-android.dotslash.
    libvidya=pinned
    if [[ -d "{{jolt_native}}/crates" ]]; then
        libvidya=checkout
        ( cd "{{jolt_native}}" && just ffi-android >/dev/null )
        mkdir -p android/prebuilt/arm64-v8a
        cp "{{jolt_native}}/build/android/arm64-v8a/libvidya.so" \
            android/prebuilt/arm64-v8a/libvidya.so
    fi
    # The boot image's other source roots are outside this cell too; hash them
    # here so the digest reaches the action. See android/BUCK.
    printf '[frq]\n  jolt_native = %s\n  android_home = %s\n  chez_android = %s\n  openssl_android = %s\n  libvidya = %s\n  boot_stamp = %s\n' \
        "{{jolt_native}}" "$android_home" "$chez" "$openssl" "$libvidya" \
        "$(android/build-jolt-boot.sh --stamp)" > .buckconfig.local
    scripts/buck2 {{args}}

# The APK, built as a graph. `just apk install` puts it on the device.
apk action="build":
    #!/usr/bin/env bash
    set -euo pipefail
    apk="$(just buck build --show-output //:apk | awk '/frq.apk/{print $2}')"
    case "{{action}}" in
      build)   printf '%s\n' "$apk" ;;
      install) "${ADB:-$HOME/.local/share/android-sdk/platform-tools/adb}" install -r "$apk" ;;
      run)
        adb="${ADB:-$HOME/.local/share/android-sdk/platform-tools/adb}"
        "$adb" install -r "$apk"
        "$adb" shell am force-stop uk.nandi.frq
        "$adb" shell am start -n uk.nandi.frq/.FrqActivity
        ;;
      log)     "${ADB:-$HOME/.local/share/android-sdk/platform-tools/adb}" logcat -s VidyaJolt Vidya ;;
      *)       echo "usage: just apk [build|install|run|log]" >&2; exit 2 ;;
    esac

# The app.
run *args:
    LD_LIBRARY_PATH="{{jolt_native}}/target/release" jolt -M:frq {{args}}
