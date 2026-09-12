# The work is here now, in recipe bodies, where it used to be in scripts/ —
# babashka scripts run through a scripts/bb that went looking for a babashka.
# That indirection bought one thing worth having, a shared way to reach nix on
# a host that keeps it in a container, and `nix` below is the whole of it.
#
# Every recipe that runs frq has the same shape: outside the dev shell, re-enter
# it and come back to this same recipe; inside, hand jolt the deps overrides and
# the library path the shell exported. The re-entry test is JOLT_NATIVE_LIB,
# which only the shell sets — no flag to forget, and no second code path for
# someone who runs `nix develop --command just run` by hand.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Every recipe below is a `#!` script and passes its arguments on with "$@".
# Without this that is empty in one — just interpolates into a shebang recipe
# rather than handing it argv — and `just tui --headless` silently ran the
# terminal instead.
set positional-arguments

# nix is not on every host this runs on: on the machine these recipes were
# written for it lives in an Arch distrobox, at the same path — which is why
# the container is entered rather than the tree copied into it. See CLAUDE.md.
nix := `command -v nix >/dev/null 2>&1 && echo nix || echo "distrobox enter arch -- nix"`

# --max-jobs 0 is what sends the work to the `builders` entry rather than
# compiling it here. Left to the default, nix prefers the local machine, and a
# cold jolt-native is egui, openh264 and quinn on a laptop — for a derivation a
# remote builder has likely built already. FRQ_MAX_JOBS=auto is the way out on
# a machine with no builder configured.
jobs := env("FRQ_MAX_JOBS", "0")

default:
    @just --list

# The APK: ClojureDart compiled to Dart, then Flutter's Gradle build.
#
# Impure on purpose, and worth saying why rather than leaving it to be
# discovered. Gradle resolves its own dependencies over the network and
# installs build-tools and a platform into ANDROID_HOME as it goes, so it
# cannot run in a sandbox and cannot write to the store. What nix gives here
# is the toolchain — clojure, a JDK, Flutter, and an SDK composed by
# androidenv — and the recipe copies that SDK somewhere writable
# (flutter/.home) for Gradle to finish off. That copy and everything Gradle
# leaves behind are gitignored.
#
# No ndkVersion in android/app/build.gradle.kts, for the same reason: the
# Flutter template sets it, setting it makes Gradle fetch that exact NDK, and
# there is no native code here to need one.
#
#   just apk                build the debug APK
#   just apk install        build it and put it on a connected device
#   just apk run            install and launch
#   just apk log            logcat, filtered to this app
apk action="build":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}/flutter"

    sdk="$(nix build --impure --no-link --print-out-paths \
        --expr 'let pkgs = import (builtins.getFlake "github:NixOS/nixpkgs/nixos-unstable") { system = "x86_64-linux"; config = { allowUnfree = true; android_sdk.accept_license = true; }; }; in (pkgs.androidenv.composeAndroidPackages { cmdLineToolsVersion = "13.0"; buildToolsVersions = [ "34.0.0" ]; platformVersions = [ "35" "34" ]; includeNDK = false; }).androidsdk')/libexec/android-sdk"

    export HOME="$PWD/.home"
    export ANDROID_HOME="$HOME/android-sdk"
    export ANDROID_SDK_ROOT="$ANDROID_HOME"
    mkdir -p "$HOME"

    # Gradle writes into ANDROID_HOME, so it is a copy rather than the store
    # path. Made once and kept: re-copying would throw away the build-tools
    # and platform Gradle installed into it on the last run.
    if [ ! -d "$ANDROID_HOME" ]; then
        cp -r "$sdk" "$ANDROID_HOME"
        chmod -R u+w "$ANDROID_HOME"
    fi

    flutter="nix shell nixpkgs#clojure nixpkgs#jdk17 nixpkgs#flutter --command"

    $flutter clojure -M:cljd compile

    # Rewritten every run: it carries absolute store paths, and the flutter
    # one moves whenever nixpkgs does.
    $flutter flutter config --android-sdk "$ANDROID_HOME" >/dev/null

    apk=build/app/outputs/flutter-apk/app-debug.apk
    adb="${ADB:-$ANDROID_HOME/platform-tools/adb}"

    case "{{action}}" in
        build)   $flutter flutter build apk --debug ;;
        install) $flutter flutter build apk --debug && "$adb" install -r "$apk" ;;
        run)     $flutter flutter build apk --debug && "$adb" install -r "$apk" \
                     && "$adb" shell monkey -p uk.nandi.frq -c android.intent.category.LAUNCHER 1 ;;
        log)     "$adb" logcat -s flutter ;;
        *)       echo "usage: just apk [build|install|run|log]" >&2; exit 1 ;;
    esac

# Two halves, and the split is the point. The frq source is the files on disk,
# uncommitted edits and all. Everything under it — jolt, glimmer, glimmer-cosmic
# and the native objects — is the flake's, built rather than fetched.
#
# Deliberately not `nix run .#frq`. That builds the flake's own copy of the
# source, which is the tree as git has it — so an edit that has not been
# committed, or committed on a branch the command was not pointed at, runs as
# whatever was there before, silently. A run meant to answer "does my change
# work" has to be the files on disk.
#
# libcosmic paints through wgpu, so this needs nixGL off NixOS for the same
# reason the window always did: the real driver is the host's.
#
# There is no jvui and no vidya here any more — both were experiments. The
# window is libcosmic and the terminal is libjolttui, and those are the two.
#
# The app: this tree's source on the flake's everything-else, in the dev shell.
run *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${JOLT_NATIVE_LIB:-}" ]; then
        exec {{nix}} develop . --max-jobs {{jobs}} --command just run "$@"
    fi

    deps="{:deps {jolt-lang/glimmer {:local/root \"$GLIMMER_SRC\"}"
    deps="$deps nandi/glimmer-cosmic {:local/root \"$GLIMMER_COSMIC_SRC\"}}}"

    export LD_LIBRARY_PATH="$JOLT_NATIVE_LIB:$FRQ_LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    runner=()
    [ -e /run/current-system ] || runner=("$NIXGL")

    exec "${runner[@]}" jolt -Sdeps "$deps" -m frq.cosmic "$@"

# `run` with the other backend under it. Only libjolttui: `frq.app` names no
# backend at all any more, and `frq.tui` requires glimmer-tui so the one
# installed is the terminal.
#
# No nixGL here, unlike `run`: a terminal wants nothing from the host's GL
# driver, which is the reason this output exists on machines that have none.
#
# The same screens in a terminal. `just tui --headless` prints one screenshot.
tui *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${JOLT_NATIVE_LIB:-}" ]; then
        exec {{nix}} develop . --max-jobs {{jobs}} --command just tui "$@"
    fi

    deps="{:deps {jolt-lang/glimmer {:local/root \"$GLIMMER_SRC\"}"
    deps="$deps nandi/glimmer-tui {:local/root \"$GLIMMER_TUI_SRC\"}}}"

    export LD_LIBRARY_PATH="$JOLT_NATIVE_LIB${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    exec jolt -Sdeps "$deps" -m frq.tui "$@"

# The same classpath as `tui`, with an nREPL on it instead of a `-main`: a
# session that can require `frq.tui` and then redefine a component while it is
# on screen, which is a second and not the minute a rebuild costs.
#
#     just nrepl                      then, from an editor or a client on 7888:
#     (require (quote frq.tui))       both backends, terminal installed last
#     (frq.tui/-main "--headless" "--demo")
#     (glimmer.core/reload!)          re-mount after redefining a component
#
# `just repl nrepl-server` is the window's half of this — the same thing minus
# glimmer-tui. Port is nrepl-server's own positional: `just nrepl 7889`.
nrepl *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${JOLT_NATIVE_LIB:-}" ]; then
        exec {{nix}} develop . --max-jobs {{jobs}} --command just nrepl "$@"
    fi

    deps="{:deps {jolt-lang/glimmer {:local/root \"$GLIMMER_SRC\"}"
    deps="$deps nandi/glimmer-tui {:local/root \"$GLIMMER_TUI_SRC\"}}}"

    export LD_LIBRARY_PATH="$JOLT_NATIVE_LIB:$FRQ_LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    exec jolt -Sdeps "$deps" nrepl-server "$@"

# `jolt` in the repo root does not work on its own: deps.edn carries
# :jolt/native, so every invocation here loads libvidya and libjoltmoq before it
# reads a line, and dies naming the library if the loader cannot find them. So
# this is `run` without the app — and `run` is this with a window's worth of
# extra care about the GL driver.
#
# A jolt with the native libraries under it: a REPL, or `just repl nrepl-server`.
repl *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${JOLT_NATIVE_LIB:-}" ]; then
        exec {{nix}} develop . --max-jobs {{jobs}} --command just repl "$@"
    fi

    deps="{:deps {jolt-lang/glimmer {:local/root \"$GLIMMER_SRC\"}"
    deps="$deps nandi/glimmer-cosmic {:local/root \"$GLIMMER_COSMIC_SRC\"}}}"

    export LD_LIBRARY_PATH="$JOLT_NATIVE_LIB:$FRQ_LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    exec jolt -Sdeps "$deps" "$@"

# Regenerate src/frq/moq/raw.clj from the libmoq_ffi we actually load.
#
# UniFFI embeds its interface metadata in the object, so `uniffi-bindgen
# --library` reads the truth out of the .so rather than a header shipped
# beside it. Those differ at one version number: the published Linux and
# Android objects are built without moq-ffi's `audio` and `video` features
# (206 functions, no codecs), while the shipped C header describes the Apple
# build (230). The object is the only source this recipe will accept.
#
# The bindgen must match the uniffi that built the object — 0.32 for moq-ffi
# 0.3.17 — and it is built once into the scratch dir rather than pinned into
# the flake: nothing in a normal build needs it, and a regeneration is a thing
# done when the moq-ffi pin moves, by hand, on purpose.
#
#   just gen-moq                     # the loaded library
#   just gen-moq path/to/libmoq_ffi.so
#
# Regenerate the libmoq_ffi bindings from the object's own embedded metadata.
gen-moq lib="":
    #!/usr/bin/env bash
    set -euo pipefail
    lib="${1:-${JOLT_NATIVE_LIB:-}/libmoq_ffi.so}"
    [ -f "$lib" ] || { echo "no libmoq_ffi.so at $lib — pass one: just gen-moq <path>" >&2; exit 1; }
    work="${TMPDIR:-/tmp}/frq-gen-moq"
    mkdir -p "$work/ubg/src"
    cat > "$work/ubg/Cargo.toml" <<'TOML'
    [package]
    name = "ubg"
    version = "0.1.0"
    edition = "2021"
    [[bin]]
    name = "uniffi-bindgen"
    path = "src/main.rs"
    [dependencies]
    uniffi = { version = "0.32", features = ["cli"] }
    TOML
    echo 'fn main() { uniffi::uniffi_bindgen_main() }' > "$work/ubg/src/main.rs"
    ( cd "$work/ubg" && cargo build --release -q )
    ( cd "$work/ubg" && ./target/release/uniffi-bindgen generate \
        --library "$lib" --language python --out-dir "$work/py" --no-format )
    python3 tools/py2jolt.py "$work"/py/*.py > "$work/body.clj"
    { sed -n '1,/^  (:require \[jolt.ffi :as ffi\]))$/p' src/frq/moq/raw.clj; echo; cat "$work/body.clj"; } > "$work/raw.clj"
    mv "$work/raw.clj" src/frq/moq/raw.clj
    echo "wrote src/frq/moq/raw.clj ($(grep -c '^(ffi/defcfn' src/frq/moq/raw.clj) entry points)"
