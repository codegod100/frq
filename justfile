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

# The build itself is nix/android.nix, reached as `.#apk`; this only asks nix
# for the file and then does what was asked with it. Nothing here names an
# Android SDK, an NDK, a Chez cross target or an OpenSSL: the derivation builds
# or fetches every one of them.
#
# The APK is signed with a debug key generated inside the derivation, so the
# output is installable and not reproducible; anything meant for a store gets
# signed from `.#apk-unsigned` instead. See nix/android.nix.
#
# FRQ_NIX_STORE builds the whole graph somewhere else rather than here —
#
#     FRQ_NIX_STORE=ssh-ng://eu.nixbuild.net just apk
#
# which is the shape android.nix asks for: with a `builders` entry instead, nix
# copies every remotely-built output back, and androidenv's NDK is both
# preferLocalBuild and absent from cache.nixos.org, so 3.1 GB of toolchain is
# built here and uploaded. With the remote as the *store* only .drv files go
# up. An install then needs the file here, so it is fetched back at the end —
# one APK rather than the closure that made it.
#
# The APK, out of the flake. `just apk install` puts it on the device.
apk action="build":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    adb="${ADB:-$HOME/.local/share/android-sdk/platform-tools/adb}"
    package="uk.nandi.frq"

    # --eval-store auto goes with a remote store and only with one: evaluation
    # wants this tree, which is here.
    store=()
    [ -n "${FRQ_NIX_STORE:-}" ] && store=(--store "$FRQ_NIX_STORE" --eval-store auto)

    build() {
        # The Android objects come from jolt-native's CI under a "latest" alias,
        # and a flake input is locked once and then stays put — so without this
        # an APK is built against whatever flake.lock recorded the first time,
        # however old. Only this input: a bare `nix flake update` would move
        # jolt, nixpkgs and glimmer too, and the point of their pins is that
        # they move when someone decides they should.
        {{nix}} flake update jolt-native-android --flake . >&2

        # Built without a `result` symlink: the path is what the caller wants,
        # and a symlink into a store that may not be this one is not a useful
        # thing to leave in the tree.
        local out
        out=$({{nix}} build .#apk --no-link --print-out-paths "${store[@]}" \
              | grep '^/nix/store/' | tail -1)
        [ -n "$out" ] || { echo "nix build printed no store path" >&2; exit 1; }

        # Off a remote store the path names a file on the builder, so adb has
        # nothing to open. `nix copy --from` brings just that one path here.
        if [ -n "${FRQ_NIX_STORE:-}" ]; then
            {{nix}} copy --no-check-sigs --from "$FRQ_NIX_STORE" "$out" >&2
        fi
        echo "$out"
    }

    case "{{action}}" in
        build)   build ;;
        install) "$adb" install -r "$(build)" ;;
        run)     file=$(build)
                 "$adb" install -r "$file"
                 "$adb" shell am force-stop "$package"
                 "$adb" shell am start -n "$package/.FrqActivity" ;;
        log)     "$adb" logcat -s VidyaJolt Vidya ;;
        *)       echo "usage: just apk [build|install|run|log]" >&2; exit 1 ;;
    esac

# Two halves, and the split is the point. The frq source is the files on disk,
# uncommitted edits and all. Everything under it — jolt, glimmer, glimmer-vidya,
# both native objects — is the flake's, built rather than fetched.
#
# Deliberately not `nix run .#frq`. That builds the flake's own copy of the
# source, which is the tree as git has it — so an edit that has not been
# committed, or committed on a branch the command was not pointed at, runs as
# whatever was there before, silently. A run meant to answer "does my change
# work" has to be the files on disk.
#
# The app: this tree's source on the flake's everything-else, in the dev shell.
run *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${JOLT_NATIVE_LIB:-}" ]; then
        exec {{nix}} develop . --max-jobs {{jobs}} --command just run "$@"
    fi

    # The Jolt halves that have to match those objects. glimmer-vidya lives
    # inside jolt-native and binds libvidya's ABI, so it comes out of the same
    # input that was built rather than deps.edn's git sha — the pin drifting
    # from the library is exactly what the flake input's comment describes.
    deps="{:deps {jolt-lang/glimmer {:local/root \"$GLIMMER_SRC\"}"
    deps="$deps nandi/glimmer-vidya {:local/root \"$GLIMMER_VIDYA_SRC\"}}}"

    export LD_LIBRARY_PATH="$JOLT_NATIVE_LIB:$FRQ_LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    # On NixOS the store's Mesa is the system's and the window opens. Anywhere
    # else — a bare host, or the distrobox above — the real driver is the
    # host's, so defer to nixGL, which prepends it.
    runner=()
    [ -e /run/current-system ] || runner=("$NIXGL")

    exec "${runner[@]}" jolt -Sdeps "$deps" -M:frq "$@"

# `run` with the other backend under it. It still loads libvidya as well as
# libjolttui: `frq.app` requires glimmer-vidya, and `frq.tui` requires
# glimmer-tui after it so the backend installed last is the terminal.
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
    deps="$deps nandi/glimmer-vidya {:local/root \"$GLIMMER_VIDYA_SRC\"}"
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
    deps="$deps nandi/glimmer-vidya {:local/root \"$GLIMMER_VIDYA_SRC\"}"
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
    deps="$deps nandi/glimmer-vidya {:local/root \"$GLIMMER_VIDYA_SRC\"}}}"

    export LD_LIBRARY_PATH="$JOLT_NATIVE_LIB:$FRQ_LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    exec jolt -Sdeps "$deps" "$@"

# Regenerate src/frq/moq/raw.clj from the libmoq_ffi we actually load.
#
# UniFFI embeds its interface metadata in the object, so `uniffi-bindgen
# --library` reads the truth out of the .so rather than a header shipped
# beside it — which for this release is a different build entirely (the Apple
# artifact has moq-ffi's `audio` and `video` features, Linux and Android do
# not). Binding the header would link on a Mac and fail on both platforms frq
# ships to, so the object is the only source this recipe will accept.
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
