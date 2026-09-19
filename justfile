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
#   just modal CONTAINER   dev
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

# The toolchain, directly: `just tools versions`,
# `just tools exec -- flutter doctor`.
[doc('the toolchain itself: versions, exec -- CMD')]
tools *args:
    #!/usr/bin/env bash
    cd "{{root}}"
    exec "{{tc}}" "$@"

# Build a target.
#
#   desktop    the app: Nim owns the state and the screens, Flutter paints
#   lib        the Nim core alone, as build/nim/libfrqcore.so
#
# There were four more. `apk` and `web` compiled ClojureDart and went with it:
# the web target cannot come back without a wasm build of the core, since a
# browser has no dart:ffi, and the APK wants libfrqcore.so cross-compiled for
# Android's ABIs. `ui` and `app` were the two halves of the migration, and
# there is one app now.
[doc('build a target: desktop lib')]
build target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        desktop) just _flutter desktop build ;;
        lib)     just _nim-lib ;;
        *)       echo "usage: just build [desktop|lib]" >&2; exit 1 ;;
    esac

# Build a target and start it.
#
#   FRQ_TRACE=1        every line in and out, both languages in one log
#   FRQ_AUTOCONNECT=1  press Connect at startup, for a window a script cannot
#                      click; FRQ_NICK overrides the nickname
[doc('build the app and start it')]
run target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        desktop) just _flutter desktop run ;;
        *)       echo "usage: just run [desktop]" >&2; exit 1 ;;
    esac

# Test a suite.
#
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
[doc('run a suite: all nim dart layout live')]
test suite="all" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    shift
    case "{{suite}}" in
        all)    just test nim && just test dart && just test layout ;;
        layout) just _nim-lib
                just _flutter layout test ;;
        nim)    just _nim-test "$@" ;;
        dart)   just _nim-lib
                exec "{{tc}}" exec -- bash -c \
                    'cd dart/frq_core && dart pub get && dart test -r expanded' ;;
        live)   just _nim-lib
                exec "{{tc}}" exec -- bash -c \
                    'cd dart/frq_core && dart pub get >/dev/null && dart run tool/live_ui.dart "$@"' _ "$@" ;;
        *)      echo "usage: just test [all|nim|dart|layout|live]" >&2; exit 1 ;;
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
#   just modal dev --shell
[doc('run a .modal/ container on Modal')]
modal container="dev" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    shift || true
    exec modal run ".modal/{{container}}/container.py" "$@"

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

[private]
_flutter target action:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    just _nim-lib
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd flutter
        # Nim resolves OpenSSL through dynlib at run time; without the host
        # library on the loader path `newContext` dies in a SIGSEGV that says
        # nothing about SSL.
        export LD_LIBRARY_PATH="${FRQ_OPENSSL_LIB:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
        flutter pub get
        case "$1:$2" in
            desktop:build) exec flutter build linux --debug ;;
            desktop:run)   exec flutter run -d linux ;;
            # Widget tests, which lay every screen out for real. Headless: no
            # GL and no window, which is what makes them the check a Wayland
            # window cannot be.
            layout:test)   exec flutter test test/nim_layout_test.dart ;;
            *) echo "unknown target/action: $1 $2" >&2; exit 1 ;;
        esac' _ "{{target}}" "{{action}}"
