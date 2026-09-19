# The work is here now, in recipe bodies, where it used to be in scripts/ —
# babashka scripts run through a scripts/bb that went looking for a babashka.
# That indirection bought one thing worth having, a shared way to reach nix on
# a host that keeps it in a container, and `nix` below is the whole of it.
#
# Every recipe that runs frq has the same shape: outside the dev shell, re-enter
# it and come back to this same recipe; inside, hand jolt the deps overrides and
# the library path the shell exported. The re-entry test is JOLT_NATIVE_LIB,
# which only the shell sets — no flag to forget, and no second code path for
# someone who runs `nix develop --command just cosmic run` by hand.

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

# Re-read the COSMIC theme into the APK.
#
# libcosmic asks cosmic-config for the accent and the surfaces at run time, so
# `just cosmic run` already follows COSMIC Settings as it changes. A phone has
# no cosmic-config, so the APK carries them instead — read here, on the machine
# that has them, and compiled in. That is the one real difference between the
# two, and it is why the generated file is in git rather than gitignored: a
# checkout on a machine with no COSMIC still builds.
#
# Run it after changing the theme in COSMIC Settings, then `just apk`.
theme:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    python3 tools/cosmic2cljd.py flutter/src/frq/theme/cosmic.cljd

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

    # The flake's, not an --impure --expr against whatever nixos-unstable is
    # today: the licence config the SDK needs lives in `androidPkgsFor` now,
    # so this is an ordinary output at the rev flake.lock pins.
    sdk="$(nix build --no-link --print-out-paths \
        "{{justfile_directory()}}#android-sdk")/libexec/android-sdk"

    # adb keeps the key the phone has already trusted under the real HOME, and
    # HOME moves below so Gradle can write into the SDK copy. Told where to
    # look, adb keeps its identity; left to find $HOME/.android it generates a
    # new one, the device stops recognising this machine, and the deploy ends
    # in "no devices/emulators found" while `adb devices` in any other shell
    # lists it perfectly well.
    export ANDROID_USER_HOME="${ANDROID_USER_HOME:-$HOME/.android}"

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

    # The compile's three caches, same flake-output-and-copy shape as the SDK
    # and for the same reason: tools.deps and pub both write into theirs, and
    # the store is read-only. What this buys is the "Resolving dependencies…
    # Downloading packages…" that used to open every run.
    deps="$(nix build --no-link --print-out-paths \
        "{{justfile_directory()}}#cljd-deps")"

    # Neither of these follows HOME. Both are read off the JVM's user.home,
    # which comes from /etc/passwd rather than the environment — so moving
    # HOME below is not enough to move them, and left alone they would be the
    # real ~/.m2 and ~/.gitlibs, shared with every other project on the box.
    export GITLIBS="$HOME/gitlibs"
    m2="$HOME/m2"
    export PUB_CACHE="$HOME/.pub-cache"

    # Seeded once each and then left alone, exactly as ANDROID_HOME is: after
    # the first compile these hold whatever the working tree has asked for
    # since, and re-copying would throw that away.
    seed() {
        [ -e "$2" ] && return 0
        mkdir -p "$(dirname "$2")"
        cp -r "$deps/$1" "$2"
        chmod -R u+w "$2"
    }
    seed m2 "$m2"
    seed gitlibs "$GITLIBS"
    seed pub-cache "$PUB_CACHE"
    seed clojuredart/cache "$PWD/.clojuredart/cache"

    # Also the flake's. `nix shell nixpkgs#...` read the registry, which is a
    # different and unlocked nixpkgs — the Flutter that built the APK could
    # move under it without flake.lock changing a line.
    flutter="nix develop {{justfile_directory()}}#flutter --command"

    # cljd-deps ships the analyzer project unresolved — a fixed-output
    # derivation may not name the store, and a resolved pub project is
    # nothing but store paths. So it is resolved here instead, offline,
    # against the cache that derivation did fetch. ClojureDart reaches for the
    # network only when bin/analyzer.dart is missing, and after this it is not.
    for helper in .clojuredart/cache/*/cljd_helper; do
        [ -d "$helper" ] || continue
        [ -e "$helper/.dart_tool/package_config.json" ] && continue
        ( cd "$helper" && $flutter flutter pub get --offline )
    done

    $flutter clojure -Sdeps "{:mvn/local-repo \"$m2\"}" -M:cljd compile

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
#
# Named for the backend rather than for the verb, the way `flutter-desktop`
# is: two desktop GUIs, neither of them the default one.
#
#   just cosmic run [args...]       open the window
cosmic action="run" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ "{{action}}" != "run" ]; then
        echo "usage: just cosmic run [args...]" >&2
        exit 1
    fi
    shift
    if [ -z "${JOLT_NATIVE_LIB:-}" ]; then
        exec {{nix}} develop . --max-jobs {{jobs}} --command just cosmic run "$@"
    fi

    deps="{:deps {jolt-lang/glimmer {:local/root \"$GLIMMER_SRC\"}"
    deps="$deps nandi/glimmer-cosmic {:local/root \"$GLIMMER_COSMIC_SRC\"}}}"

    export LD_LIBRARY_PATH="$JOLT_NATIVE_LIB:$FRQ_LIB_PATH${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

    runner=()
    [ -e /run/current-system ] || runner=("$NIXGL")

    exec "${runner[@]}" jolt -Sdeps "$deps" -m frq.cosmic "$@"

# `cosmic` with the other backend under it. Only libjolttui: `frq.app` names no
# backend at all any more, and `frq.tui` requires glimmer-tui so the one
# installed is the terminal.
#
# No nixGL here, unlike `cosmic`: a terminal wants nothing from the host's GL
# driver, which is the reason this output exists on machines that have none.
#
# What may appear in common/, checked — the half of the tree both backends
# compile. Needs nothing built: it reads the source, so it is the one check
# that runs anywhere, and CI runs exactly this.
check-common:
    #!/usr/bin/env bash
    python3 tools/check-common.py common

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
# this is `cosmic` without the app — and `cosmic` is this with a window's
# worth of
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

# The other desktop GUI: the same screens, painted by Flutter instead of
# libcosmic.
#
# `just cosmic run` and this one are two frontends over one tree, and the
# split is the same one the APK already draws. Everything under `common/` — the
# screens, the cells, `frq.io` — is shared; what differs is who paints it and
# who answers the host. So this recipe is `just apk` with the Android half
# taken out: the same `clojure -M:cljd compile` over the same flutter/src,
# then Flutter's Linux target rather than its Android one. CMake and Ninja
# instead of Gradle, `flutter/linux/` as the runner, no SDK and no JDK.
#
# Still impure, for one of the two reasons `apk` is: pub.dev resolution and
# Flutter's own engine artifacts are network. What it does NOT need is the
# writable-ANDROID_HOME dance — nothing here writes into the store — so there
# is no `flutter/.home` on this path.
#
# nixGL for the reason `cosmic` needs it and `tui` does not: Flutter paints
# through GL, and off NixOS the driver is the host's.
#
#   just flutter-desktop            build the debug bundle
#   just flutter-desktop run        build it and open the window
flutter-desktop action="build":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${FRQ_FLUTTER_DESKTOP:-}" ]; then
        exec {{nix}} develop .#flutter-desktop --max-jobs {{jobs}} \
            --command just flutter-desktop "$@"
    fi
    cd flutter

    # The same three caches `just apk` seeds, in the same place and out of the
    # same flake output — one compiler, one set of dependencies, and no reason
    # for the two frontends to keep a copy each. `.home/` is `apk`'s directory
    # by name and this is the only thing put there from here, which is the
    # point: whichever recipe runs first pays for the copy and the other finds
    # it warm.
    #
    # No `nix build` here, unlike `apk`: this recipe is already inside the
    # shell that names FRQ_CLJD_DEPS by the time it gets this far, and `apk`
    # needs the path before it enters anything.
    #
    # m2 and gitlibs are set here for the reason they are set there — the JVM
    # reads user.home out of /etc/passwd, so neither follows HOME and left
    # alone they are the real ~/.m2 and ~/.gitlibs.
    export PUB_CACHE="$PWD/.home/.pub-cache"
    export GITLIBS="$PWD/.home/gitlibs"
    m2="$PWD/.home/m2"

    seed() {
        [ -e "$2" ] && return 0
        mkdir -p "$(dirname "$2")"
        cp -r "$FRQ_CLJD_DEPS/$1" "$2"
        chmod -R u+w "$2"
    }
    seed m2 "$m2"
    seed gitlibs "$GITLIBS"
    seed pub-cache "$PUB_CACHE"
    seed clojuredart/cache "$PWD/.clojuredart/cache"

    # Resolved here rather than in cljd-deps, which was not allowed to name
    # the store — see the same loop in `apk`.
    for helper in .clojuredart/cache/*/cljd_helper; do
        [ -d "$helper" ] || continue
        [ -e "$helper/.dart_tool/package_config.json" ] && continue
        ( cd "$helper" && flutter pub get --offline )
    done

    clojure -Sdeps "{:mvn/local-repo \"$m2\"}" -M:cljd compile
    flutter build linux --debug

    # x64/arm64 is Flutter's own name for the host arch, not uname's.
    case "$(uname -m)" in
        x86_64)  arch=x64 ;;
        aarch64) arch=arm64 ;;
        *)       echo "unknown arch $(uname -m)" >&2; exit 1 ;;
    esac
    bundle="build/linux/$arch/debug/bundle"

    case "{{action}}" in
        build) echo "built $PWD/$bundle/frq" ;;
        run)
            runner=()
            [ -e /run/current-system ] || runner=("$NIXGL")
            exec "${runner[@]}" "$bundle/frq"
            ;;
        *) echo "usage: just flutter-desktop [build|run]" >&2; exit 1 ;;
    esac

# The third frontend: the same screens again, compiled to JavaScript.
#
# `flutter-desktop` with the Linux half taken out. One `clojure -M:cljd
# compile` over the same flutter/src and common/, then Flutter's web target
# instead of its Linux one — dart2js instead of CMake and Ninja, and a
# directory of static files instead of a bundle with an executable in it.
#
# And the one target with no nix in it. The other two need the host: a JDK
# and the Android SDK for `apk`, GTK and a C++ toolchain and nixGL for
# `flutter-desktop`. This one needs a Dart, a JVM and a browser, and the
# browser is not ours — so `tools/toolchain.sh` fetches the first two as
# pinned tarballs into `.toolchain/` and there is nothing left for a devShell
# to supply. That is what lets the container in `.modal/flutter-web/` drop
# its image build too: same script, same three pins, no store to populate.
#
# Impure for the reason the other two are: pub.dev resolution and Flutter's
# engine artifacts are network, and now the toolchain is as well — pinned by
# sha256, which is the reproducibility that was worth having out of the store.
#
# The entry point is `frq.main-web`, not `frq.main`: path_provider has no web
# implementation, so the `getApplicationSupportDirectory` that `frq.main`
# awaits throws MissingPluginException before any widget is built. The web
# entry installs `frq.io.web` — localStorage behind the same seam — and awaits
# nothing. `frq.net.dart` is still the socket half, so connecting will want a
# WebSocket before this does more than paint.
#
# One build and no `--debug` variant, because there is nothing to gain from
# one: dart2js at -O1 measured 52.5s against the release build's 49.8s on the
# same source change here, so a second, larger bundle would buy noise. See
# `tools/build-web.sh`, which writes the numbers down.
#
#   just flutter-web                build build/web
#   just flutter-web serve          build it and serve it on $PORT (8080)
#   just flutter-web serve 3000     ...on another port
flutter-web action="build" port="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    # A wrapper and nothing else. The build is a shell script because the
    # container runs it too, and a container that had to install `just` to
    # start would be one dependency away from the point.
    exec "{{justfile_directory()}}/tools/build-web.sh" {{action}} {{port}}

# The cosmic GUI as a directory anyone can unpack, with no nix on either end.
#
# `just cosmic run` is the edit loop — a devShell, this tree's source, a store
# path per dependency. This is the other end of the same program: a jolt
# binary, the backends out of jolt-native's portable tarball, libmoq_ffi off
# its release, glimmer and glimmer-cosmic at pinned revs, and one .c file
# compiled on the spot. `tools/desktop-toolchain.sh` fetches; nothing is
# built from source that somebody else has already published.
#
# It replaces `nix build .#appimage`, and what it drops with it is the reason
# that output existed. nix-appimage squashed a closure into one file so a
# machine without nix could run it, and the heaviest thing in that closure was
# a Mesa — carried so that nixGL had something to put the host driver in front
# of. There is no Mesa here, so there is no nixGL: the GL driver is the
# host's, the way it is for everything else on the machine.
#
#   just desktop            assemble build/desktop
#   just desktop tar        ...and tar it up for another machine
#   just desktop run        ...and start it
desktop action="build":
    #!/usr/bin/env bash
    set -euo pipefail
    # A wrapper and nothing else, for the reason `flutter-web` is one: the
    # container runs the same script, and a container that had to install
    # `just` first would be one dependency away from the point.
    exec "{{justfile_directory()}}/tools/build-desktop.sh" {{action}}

# The containers in `.modal/`, run on Modal rather than here. This machine
# evaluates and Modal builds — see CLAUDE.md, which says so rather more
# firmly — and these two recipes are the whole interface to that.
#
# Named for where the work happens, the way `cosmic` and `flutter-desktop`
# are named for what paints: there is no re-entry test here because nothing
# re-enters. There is no `nix` variable either, and that used to be because
# nix ran out there — now it is because two of these three containers have no
# nix in them at all.
#
#   just modal frq                 assemble the desktop bundle on Modal
#   just modal flutter-dev         the incremental Flutter loop
modal container="frq" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    shift
    exec modal run ".modal/{{container}}/container.py" "$@"

# The Modal-built web bundle, served from this machine on localhost.
#
# Not a local build: `modal volume get` pulls what `just modal flutter-web`
# already compiled out of the devshell volume, so this needs no Flutter, no
# Dart and no nix — only python, which the flake shell has and so does the
# machine.
#
# It exists for one reason, and the reason is the auth broker rather than
# convenience. freeq's broker finishes an OAuth login by redirecting the
# browser to `return_to`, and it will only redirect to an origin on its
# allowlist: its own https hosts, and `http://localhost` or `http://127.0.0.1`
# on ANY port. A build served from anywhere else — the Modal URL included —
# gets `400 Invalid return_to URL` and can never complete a Bluesky sign-in,
# no matter what the client does. localhost is the one allowlisted origin we
# can serve from, so this is how Bluesky sign-in is tested.
#
# Guest and app-password sign-in need none of this; they work on the deployed
# URL, because neither goes near the broker.
#
#   just web-local             fetch and serve on :8080
#   just web-local 3000        another port; any port is allowlisted
web-local port="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    out="{{justfile_directory()}}/.web-local"
    mkdir -p "$out"
    echo "fetching the Modal-built bundle…"
    # --force: this is a mirror of the volume, and a stale file left behind
    # would be served in preference to the one just built.
    modal volume get --force devshell frq-flutter-web/flutter/build/web "$out"
    echo
    echo "  http://localhost:{{port}}"
    echo
    echo "Bluesky sign-in works here and not on the Modal URL: the broker"
    echo "allowlists localhost on any port. Put wss://irc.freeq.at/irc in the"
    echo "Server field — a browser has no TCP."
    exec python3 -m http.server {{port}} --bind 127.0.0.1 --directory "$out/web"

# A sandbox left running with the container's own image, volumes and
# environment, and the command to get into it. `modal shell --image` cannot
# be pointed at a published Modal image like arch-nix, so attaching to a
# running sandbox is the only way to get a shell that is the container.
#
# It blocks: an ephemeral app stops when its entrypoint returns and takes the
# sandbox with it. Attach from a second terminal, and Ctrl-C here when done —
# the sandbox bills until you do.
#
#   just modal-shell               flutter-dev, the usual one
#   just modal-shell frq           the desktop bundle container
modal-shell container="flutter-dev":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    exec modal run ".modal/{{container}}/container.py" --shell
