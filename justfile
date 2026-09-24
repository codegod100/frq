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
#   just deploy web        the CI-built image, to a Modal URL
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
#   web        the same, in a browser: the core compiled by `nim js`, the
#              socket a WebSocket to freeq's own bridge, Flutter painting
#   lib        the Nim core alone, as build/nim/libfrqcore.so
#   core-js    the core alone, as build/web/frq_core.js
#
# There were four more. `apk` and `web` compiled ClojureDart and went with it:
# the web target cannot come back without a wasm build of the core, since a
# browser has no dart:ffi, and the APK wants libfrqcore.so cross-compiled for
# Android's ABIs. `ui` and `app` were the two halves of the migration, and
# there is one app now.
[doc('build a target: desktop web lib core-js')]
build target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        desktop) just _flutter desktop build ;;
        web)     just _web-bundle ;;
        lib)     just _nim-lib ;;
        core-js) just _nim-js ;;
        *)       echo "usage: just build [desktop|web|lib|core-js]" >&2; exit 1 ;;
    esac

# Build a target and start it.
#
#   FRQ_TRACE=1        every line in and out, both languages in one log
#   FRQ_AUTOCONNECT=1  press Connect at startup, for a window a script cannot
#                      click; FRQ_NICK overrides the nickname
[doc('build the app and start it: desktop web')]
run target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        desktop) just _flutter desktop run ;;
        web)     just _web-bundle
                 exec python3 tools/webserve.py 8000 build/web ;;
        *)       echo "usage: just run [desktop|web]" >&2; exit 1 ;;
    esac

# Test a suite.
#
#   nim      the Nim core. No Flutter, no Dart, no SDK — a rule about the IRC
#            wire format is checkable in a second.
#   dart     the Dart side of the FFI boundary, on the plain Dart VM. Passing
#            `nim` and failing this one is a marshalling bug, which is why the
#            two are separate suites.
#   web      the JavaScript build of the same core, driven as a browser
#            drives it. Needs node and nothing else.
#   live     the whole stack against a real freeq. Not in `all`: it wants a
#            network and a running server.
#
#   just test              all of them
#   just test nim tircparse    one Nim file
[doc('run a suite: all nim dart layout web live')]
test suite="all" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    shift
    case "{{suite}}" in
        all)    just test nim && just test dart && just test layout \
                             && just test web ;;
        layout) just _nim-lib
                just _flutter layout test ;;
        nim)    just _nim-test "$@" ;;
        web)    just _nim-js
                node nim/web/test/smoke.js build/web/frq_core.js
                node nim/web/test/session.js
                exec python3 nim/web/test/serve.py ;;
        dart)   just _nim-lib
                exec "{{tc}}" exec -- bash -c \
                    'cd dart/frq_core && dart pub get && dart test -r expanded' ;;
        live)   just _nim-lib
                exec "{{tc}}" exec -- bash -c \
                    'cd dart/frq_core && dart pub get >/dev/null && dart run tool/live_ui.dart "$@"' _ "$@" ;;
        *)      echo "usage: just test [all|nim|dart|layout|web|live]" >&2; exit 1 ;;
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

# Deploy, rather than run: a URL that stays up between pushes.
#
# Nothing is built here. `.modal/web/` points at an image CI already made
# and pushed, and FRQ_WEB_IMAGE is which tag of it — so this is the same
# command the `web` workflow's deploy job runs, with the tag named by hand
# instead of by the commit. Normally you want the job; this is for deploying an older tag, or a
# first deploy before CI has one.
#
#   FRQ_WEB_IMAGE=ghcr.io/nandithebull/frq-web:<sha> just deploy web
[doc('deploy a .modal/ container as a URL (needs FRQ_WEB_IMAGE)')]
deploy container="web":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    if [ -z "${FRQ_WEB_IMAGE:-}" ]; then
        echo "deploy: set FRQ_WEB_IMAGE to the image tag CI pushed" >&2
        echo "  e.g. ghcr.io/nandithebull/frq-web:\$(git rev-parse HEAD)" >&2
        exit 1
    fi
    # Every deploy target supplies an explicit Modal entrypoint.
    spec=".modal/{{container}}/deploy.py"
    [ -f "$spec" ] || {
        echo "deploy: missing Modal entrypoint: $spec" >&2
        exit 1
    }
    exec modal deploy "$spec"

# The same core, compiled to JavaScript.
#
# `--path:src --path:web`, in that order, because the later path wins: every
# module under `nim/web/frq` shadows the one beside it in `nim/src/frq`, so
# `frq/conn` is a queue the host fills rather than two socket threads, and the
# shared code above them never learns which host it is on.
# The web bundle: the core as JavaScript, and Flutter around it.
#
# The core goes into `flutter/web/` rather than being copied afterwards,
# because `flutter build web` copies that directory into the bundle — so the
# page's `<script src="frq_core.js">` resolves the same in a dev server as it
# does in the built output.
[private]
_web-bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    just _nim-js
    cp build/web/frq_core.js flutter/web/frq_core.js
    # Where this bundle will be served from. Every value in the client
    # metadata is absolute — the `client_id` has to equal the URL the document
    # is served from — so the origin is a build input rather than something
    # the page can work out for itself.
    #
    # The default is the dev server `just run web` starts. A page served from
    # there cannot complete a Bluesky sign-in: an authorization server will
    # not fetch client metadata over http from a non-loopback host, and this
    # is `localhost` only when it is. Guest works everywhere.
    python3 tools/client-metadata.py "${FRQ_WEB_ORIGIN:-http://localhost:8000}" \
        > flutter/web/client-metadata.json
    # `--pwa-strategy=none` leaves out Flutter's service worker, and
    # `flutter/web/frq_sw.js` is registered in its place. The page is still
    # a PWA -- a browser will not offer to install one without a worker that
    # handles fetches -- but not that worker: Flutter's is offline-first, so
    # a new copy of it waits for every tab on the origin to close before it
    # takes over, and until then the app serves the bundle it already had.
    # Twice in one afternoon a working fix read as broken because of it.
    # Ours is network-first and claims its clients at once.
    #
    # The comment lives out here rather than inside the quoted script below,
    # which is single-quoted -- an apostrophe in there ends the string, and
    # the build silently stopped after `pub get` and still exited 0.
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd flutter
        flutter pub get
        flutter build web --pwa-strategy=none
        rm -rf ../build/web
        cp -r build/web ../build/web
        echo "built build/web"'

[private]
_nim-js:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    out="{{root}}/build/web"
    mkdir -p "$out"
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        nim js -d:release --hints:off \
            --path:src --path:web --out:"'"$out"'/frq_core.js" web/frq_web.nim
        printf "built %s (%s)\n" "'"$out"'/frq_core.js" \
            "$(gzip -9c "'"$out"'/frq_core.js" | wc -c | awk "{printf \"%d KB gzipped\", \$1/1024}")"'

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
