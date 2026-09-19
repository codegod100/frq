# Six verbs over one tree.
#
# There is no nix here any more. `tools/toolchain.sh` fetches Flutter (which
# carries Dart), a JDK, the Clojure CLI and Nim as sha256-pinned tarballs into
# `.toolchain/`, and every recipe below runs inside the environment that
# script prints. One mechanism, and the same one the containers in `.modal/`
# use — which is what lets a plain Debian image build this.
#
# What the host still brings: a C compiler (Nim shells out to one), OpenSSL
# (nim.cfg is `-d:ssl`), git, curl, unzip, python3. For `run desktop` and the
# other Linux builds, GTK and the usual CMake/Ninja/pkg-config.
#
#   just build TARGET      apk desktop web lib ui app
#   just run TARGET        apk desktop web ui app
#   just test SUITE        all nim dart common live
#   just modal CONTAINER   dev web
#   just serve [PORT]      the Modal-built web bundle, on localhost
#   just tools ...         the toolchain itself

set shell := ["bash", "-euo", "pipefail", "-c"]

# Every recipe is a `#!` script. Without this, "$@" is empty in one of them —
# just interpolates into a shebang recipe rather than handing it argv.
set positional-arguments

root := justfile_directory()
tc := justfile_directory() / "tools/toolchain.sh"

default:
    @just --list

# The toolchain, directly: `just tools versions`, `just tools android`,
# `just tools exec -- flutter doctor`.
[doc('the toolchain itself: versions, android, exec -- CMD')]
tools *args:
    #!/usr/bin/env bash
    cd "{{root}}"
    exec "{{tc}}" "$@"

# Build a target.
#
#   apk        the Android app, via Gradle
#   desktop    the ClojureDart app on Flutter's Linux target
#   web        the same screens compiled to JavaScript, into build/web
#   lib        the Nim core as build/nim/libfrqcore.so
#   ui         Nim owning the state and the screens, painted by Flutter
#   app        the ClojureDart app with the Nim core as its transport only
[doc('build a target: apk desktop web lib ui app')]
build target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        apk)     just _flutter apk build ;;
        desktop) just _flutter desktop build ;;
        web)     exec tools/build-web.sh build ;;
        lib)     just _nim-lib ;;
        ui)      just _flutter ui build ;;
        app)     just _flutter app build ;;
        *)       echo "usage: just build [apk|desktop|web|lib|ui|app]" >&2; exit 1 ;;
    esac

# Build a target and start it.
#
#   apk        install on a connected device and launch it
#   web        serve build/web on ARG (default 8080)
#   the rest   open the window
#
#   just run apk
#   just run web 3000
[doc('build a target and start it')]
run target="desktop" arg="":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        apk)     just _flutter apk run ;;
        desktop) just _flutter desktop run ;;
        web)     port="${2:-}"; exec tools/build-web.sh serve "${port:-8080}" ;;
        ui)      just _flutter ui run ;;
        app)     just _flutter app run ;;
        log)     just tools exec -- adb logcat -s flutter ;;
        *)       echo "usage: just run [apk|desktop|web|ui|app|log]" >&2; exit 1 ;;
    esac

# Test a suite.
#
#   common   what may appear in common/, read off the source. Needs no
#            toolchain at all, which is why CI runs exactly this.
#   nim      the Nim core. No Flutter, no Dart, no SDK — a rule about the IRC
#            wire format is checkable in a second.
#   dart     the Dart side of the FFI boundary, on the plain Dart VM. Passing
#            `nim` and failing this one is a marshalling bug, which is why the
#            two are separate suites.
#   live     the whole stack against a real freeq. Not in `all`: it wants a
#            network and a running server.
#
#   just test              all of them
#   just test nim tircparse    one Nim file
[doc('run a suite: all common nim dart live')]
test suite="all" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    shift
    case "{{suite}}" in
        all)    just test common && just test nim && just test dart \
                  && just test layout ;;
        common) exec python3 tools/check-common.py common ;;
        layout) just _nim-lib
                just _flutter layout test ;;
        nim)    just _nim-test "$@" ;;
        dart)   just _nim-lib
                exec "{{tc}}" exec -- bash -c \
                    'cd dart/frq_core && dart pub get && dart test -r expanded' ;;
        live)   just _nim-lib
                exec "{{tc}}" exec -- bash -c \
                    'cd dart/frq_core && dart pub get >/dev/null && dart run tool/live_ui.dart "$@"' _ "$@" ;;
        *)      echo "usage: just test [all|common|nim|dart|live]" >&2; exit 1 ;;
    esac

# The containers in `.modal/`, run on Modal rather than here: this machine
# evaluates and Modal builds. See CLAUDE.md, which says so rather more firmly.
#
# `--shell` leaves a sandbox running with the container's own image, volumes
# and environment, and prints the command to attach to it. It blocks — an
# ephemeral app takes its sandbox down when the entrypoint returns — so attach
# from a second terminal and Ctrl-C here when done. The sandbox bills until
# you do.
#
#   just modal dev
#   just modal web --shell
[doc('run a .modal/ container on Modal')]
modal container="dev" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    shift || true
    exec modal run ".modal/{{container}}/container.py" "$@"

# The Modal-built web bundle, served from this machine on localhost.
#
# Not a local build: `modal volume get` pulls down what `just modal
# web` already compiled, so this needs only python3.
#
# It exists for the auth broker rather than for convenience. freeq's broker
# finishes an OAuth login by redirecting to `return_to`, and only to an origin
# on its allowlist: its own https hosts, and http://localhost or
# http://127.0.0.1 on ANY port. Served from anywhere else — the Modal URL
# included — a Bluesky sign-in gets `400 Invalid return_to URL` and can never
# complete. Guest and app-password sign-in work on the deployed URL; neither
# goes near the broker.
[doc('serve the Modal-built web bundle on localhost')]
serve port="8080":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    out="{{root}}/.web-local"
    mkdir -p "$out"
    echo "fetching the Modal-built bundle…"
    # --force: this is a mirror of the volume, and a stale file left behind
    # would be served in preference to the one just built.
    modal volume get --force devshell frq-web/flutter/build/web "$out"
    echo
    echo "  http://localhost:{{port}}"
    echo
    echo "Bluesky sign-in works here and not on the Modal URL. Put"
    echo "wss://irc.freeq.at/irc in the Server field — a browser has no TCP."
    exec python3 -m http.server {{port}} --bind 127.0.0.1 --directory "$out/web"

# --- the work behind the verbs ------------------------------------------

# The Nim core as a shared library, into build/nim.
#
# `--mm:orc` and not refc, and it is not a preference: refc gives each thread
# its own GC heap, so the Socket the reader and writer threads share is a ref
# from another heap and dereferencing it segfaults. ORC's heap is shared.
#
# `-d:release` and not `-d:danger`: the bounds checks are what turn a
# malformed line off a socket into an exception rather than a read past the
# end of a buffer, and this parses exactly that.
[private]
_nim-lib:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    out="{{root}}/build/nim"
    mkdir -p "$out"
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        nim c --app:lib --mm:orc -d:release --hints:off \
            --path:src --out:"'"$out"'/libfrqcore.so" src/frq_core.nim
        echo "built '"$out"'/libfrqcore.so"
        nm -D --defined-only "'"$out"'/libfrqcore.so" | grep " T frq_" || true'

[private]
_nim-test *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        if [ -n "${1:-}" ]; then
            exec nim c -r --hints:off --path:src "tests/$1.nim"
        fi
        for t in tests/t*.nim; do
            echo "== $t"
            nim c -r --hints:off --path:src "$t"
        done' _ "$@"

# The three Flutter targets, which differ only in what they compile and which
# entry point they paint.
#
#   apk      ClojureDart, then Gradle. Impure on purpose: Gradle resolves its
#            own dependencies over the network and has sdkmanager install a
#            platform and build-tools into ANDROID_HOME as it goes, so the
#            SDK has to be writable — which is what `just tools android` gets
#            it. Everything it leaves behind is under `.toolchain/` and
#            gitignored.
#   desktop  the same `clojure -M:cljd compile`, Flutter's Linux target.
#   ui       no ClojureDart at all: `lib/main_nim.dart` asks the Nim core for
#            a widget tree and paints it.
#   app      `frq.main-nim` is `frq.main` with one line changed —
#            `frq.net.nim/install!` where it said `frq.net.dart/install!`.
#            Every screen, cell and action is the one that was already there.
[private]
_flutter target action:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        apk) "{{tc}}" android ;;
        ui|app|layout) just _nim-lib ;;
    esac
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd flutter
        # Nim resolves OpenSSL through dynlib at run time; without the host
        # library on the loader path `newContext` dies in a SIGSEGV that says
        # nothing about SSL.
        export LD_LIBRARY_PATH="${FRQ_OPENSSL_LIB:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        cljd() { clojure -Sdeps "{:mvn/local-repo \"$FRQ_M2\"}" -M:cljd compile "$@"; }

        case "$1:$2" in
            apk:*)
                cljd
                # Rewritten every run: it carries absolute paths.
                flutter config --android-sdk "$ANDROID_HOME" >/dev/null
                flutter build apk --debug
                apk=build/app/outputs/flutter-apk/app-debug.apk
                [ "$2" = run ] || exit 0
                adb install -r "$apk"
                exec adb shell monkey -p uk.nandi.frq \
                    -c android.intent.category.LAUNCHER 1 ;;
            desktop:build) cljd; exec flutter build linux --debug ;;
            desktop:run)   cljd; exec flutter run -d linux ;;
            ui:build)      flutter pub get
                           exec flutter build linux --debug -t lib/main_nim.dart ;;
            ui:run)        flutter pub get
                           exec flutter run -d linux -t lib/main_nim.dart ;;
            app:build)     flutter pub get; cljd frq.main-nim
                           exec flutter build linux --debug -t lib/main_nim_app.dart ;;
            app:run)       flutter pub get; cljd frq.main-nim
                           exec flutter run -d linux -t lib/main_nim_app.dart ;;
            # Widget tests, which lay every screen out for real. Headless: no
            # GL, no window, which is what makes them the check a Wayland
            # window cannot be.
            layout:test)   flutter pub get
                           exec flutter test test/nim_layout_test.dart ;;
        esac' _ "{{target}}" "{{action}}"
