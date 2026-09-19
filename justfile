# The work is here now, in recipe bodies, where it used to be in scripts/ —
# babashka scripts run through a scripts/bb that went looking for a babashka.
# That indirection bought one thing worth having, a shared way to reach nix on
# a host that keeps it in a container, and `nix` below is the whole of it.
#
# Every recipe that builds has the same shape: outside the dev shell, re-enter
# it and come back to this same recipe; inside, do the work. The re-entry test
# is an environment variable only the shell sets — no flag to forget, and no
# second code path for someone who runs `nix develop --command just ...` by
# hand.

set shell := ["bash", "-euo", "pipefail", "-c"]

# Every recipe below is a `#!` script and passes its arguments on with "$@".
# Without this that is empty in one — just interpolates into a shebang recipe
# rather than handing it argv — and a recipe silently ignored its flags.
set positional-arguments

# nix is not on every host this runs on: on the machine these recipes were
# written for it lives in an Arch distrobox, at the same path — which is why
# the container is entered rather than the tree copied into it. See CLAUDE.md.
nix := `command -v nix >/dev/null 2>&1 && echo nix || echo "distrobox enter arch -- nix"`

# --max-jobs 0 is what sends the work to the `builders` entry rather than
# compiling it here. Left to the default, nix prefers the local machine, and a
# cold Flutter toolchain is a lot of compiling on a laptop — for a derivation a
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

# What may appear in common/, checked. Needs nothing built: it reads the
# source, so it is the one check that runs anywhere, and CI runs exactly this.
check-common:
    #!/usr/bin/env bash
    python3 tools/check-common.py common

# The desktop GUI: the same screens the APK paints, on Flutter's Linux target.
#
# This recipe and `just apk` are two targets over one tree, and the split is
# the one the APK already draws. Everything under `common/` — the screens, the
# cells, `frq.io` — is shared; what differs is who answers the host. So this
# is `just apk` with the Android half taken out: the same `clojure -M:cljd compile` over the same flutter/src,
# then Flutter's Linux target rather than its Android one. CMake and Ninja
# instead of Gradle, `flutter/linux/` as the runner, no SDK and no JDK.
#
# Still impure, for one of the two reasons `apk` is: pub.dev resolution and
# Flutter's own engine artifacts are network. What it does NOT need is the
# writable-ANDROID_HOME dance — nothing here writes into the store — so there
# is no `flutter/.home` on this path.
#
# nixGL because Flutter paints through GL, and off NixOS the driver is the
# host's.
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

# The containers in `.modal/`, run on Modal rather than here. This machine
# evaluates and Modal builds — see CLAUDE.md, which says so rather more
# firmly — and these two recipes are the whole interface to that.
#
# Named for where the work happens, the way `flutter-desktop` is named for
# what paints: there is no re-entry test here because nothing
# re-enters. There is no `nix` variable either, and that used to be because
# nix ran out there — now it is because neither of these containers has any
# nix in it at all.
#
#   just modal flutter-dev         the incremental Flutter loop
#   just modal flutter-web         the web bundle
modal container="flutter-dev" *args:
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
#   just modal-shell flutter-web   the web bundle container
modal-shell container="flutter-dev":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    exec modal run ".modal/{{container}}/container.py" --shell

# The Nim core's test suite.
#
# It needs no Flutter, no Dart and no Android SDK — which is the point of
# having the logic here rather than under `common/`: a rule about the IRC wire
# format can be checked in a second, on any machine, without a toolchain that
# takes minutes to enter.
#
#   just nim-test               the whole suite
#   just nim-test tircparse     one file
nim-test file="":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${FRQ_NIM:-}" ]; then
        exec {{nix}} develop .#nim --max-jobs {{jobs}} --command just nim-test "$@"
    fi
    cd nim
    if [ -n "{{file}}" ]; then
        exec nim c -r --hints:off --path:src "tests/{{file}}.nim"
    fi
    for t in tests/t*.nim; do
        echo "== $t"
        nim c -r --hints:off --path:src "$t"
    done

# The Nim core as a shared library, into build/nim.
#
# `--mm:orc` rather than the default: this is a library loaded by a Dart
# process that owns its own lifetime, so reference counting with a cycle
# collector is the memory model that does not need a GC thread of its own or a
# stack it can scan.
#
# `-d:release` and not `-d:danger`: the bounds checks are what turn a
# malformed line off a socket into an exception instead of a read past the end
# of a buffer, and this parses exactly that.
nim-lib:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${FRQ_NIM:-}" ]; then
        exec {{nix}} develop .#nim --max-jobs {{jobs}} --command just nim-lib
    fi
    out="{{justfile_directory()}}/build/nim"
    mkdir -p "$out"
    cd nim
    nim c --app:lib --mm:orc -d:release --hints:off \
        --path:src --out:"$out/libfrqcore.so" src/frq_core.nim
    echo "built $out/libfrqcore.so"
    nm -D --defined-only "$out/libfrqcore.so" | grep ' T frq_' || true

# The Dart side of the Nim boundary, on the plain Dart VM.
#
# No Flutter, no emulator, no ClojureDart — `dart/frq_core` is ordinary Dart
# over `dart:ffi` and is not a Flutter package, so the test that proves the
# marshalling runs in a second. Passing `just nim-test` and failing this one is a
# marshalling bug, which is the whole reason the two suites are separate.
#
# Builds the library first: the test dlopens a real .so and there is no point
# reporting that it could not find one.
dart-test:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{justfile_directory()}}"
    if [ -z "${FRQ_DART:-}" ]; then
        # nim-lib before the re-entry, not after: it enters a shell of its own
        # and doing it on the far side would build the library twice.
        just nim-lib
        exec {{nix}} develop .#dart --max-jobs {{jobs}} --command just dart-test
    fi
    cd dart/frq_core
    dart pub get
    dart test -r expanded
