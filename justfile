# Five verbs over one tree.
#
# There is no nix here. `tools/toolchain.sh` fetches Nim as a sha256-pinned
# tarball into `.toolchain/`, and every recipe below runs inside the
# environment that script prints. One mechanism, and the same one the
# containers in `.modal/` use — which is what lets a plain Debian image build
# this.
#
# What the host still brings: a C compiler (Nim shells out to one), OpenSSL
# (nim.cfg is `-d:ssl`), git, curl, python3, and for the desktop, GTK 3 and
# pkg-config. `test web` wants node.
#
#   just build TARGET      desktop web lib core-js
#   just run TARGET        desktop web
#   just test SUITE        all nim web desktop
#   just modal CONTAINER   dev
#   just deploy web        the CI-built image, to a Modal URL
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
# `just tools exec -- nim --version`.
[doc('the toolchain itself: versions, exec -- CMD')]
tools *args:
    #!/usr/bin/env bash
    cd "{{root}}"
    exec "{{tc}}" "$@"

# Build a target.
#
#   desktop    the app on GTK, as build/frq: the core, and nimkit painting it
#   web        the same, in a browser, as build/web: the core and its
#              renderer compiled by `nim js`, beside the page in web/
#   lib        the core alone, as build/nim/libfrqcore.so
#   core-js    the core alone, as build/web/frq_core.js
#
# There used to be an APK, and a Flutter renderer over both of the first two.
# The APK went with ClojureDart and the renderer with Flutter: nimkit draws
# the same widget tree on GTK and in a page, so there is one language left.
[doc('build a target: desktop web lib core-js')]
build target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        desktop) just _desktop ;;
        web)     just _web-bundle ;;
        lib)     just _nim-lib ;;
        core-js) just _nim-js ;;
        *)       echo "usage: just build [desktop|web|lib|core-js]" >&2; exit 1 ;;
    esac

# Build a target and start it.
#
#   FRQ_TRACE=1        every line in and out
#   FRQ_AUTOCONNECT=1  press Connect at startup, for a window a script cannot
#                      click; FRQ_NICK overrides the nickname
#   FRQ_DEMO=1         open on a representative room, no server
#   FRQ_THEME=dark     or light; otherwise the desktop's own
[doc('build the app and start it: desktop web')]
run target="desktop":
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    case "{{target}}" in
        # Nim resolves OpenSSL through dynlib at run time; without the host
        # library on the loader path `newContext` dies in a SIGSEGV that says
        # nothing about SSL.
        desktop) just _desktop
                 export LD_LIBRARY_PATH="${FRQ_OPENSSL_LIB:-}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                 exec build/frq ;;
        web)     just _web-bundle
                 exec python3 tools/webserve.py 8000 build/web ;;
        *)       echo "usage: just run [desktop|web]" >&2; exit 1 ;;
    esac

# Test a suite.
#
#   nim      the Nim core. No GTK and no browser — a rule about the IRC wire
#            format is checkable in a second.
#   web      the JavaScript build of the same core, driven as a browser
#            drives it, and the page's own app compiled. Needs node.
#   desktop  the GTK app compiled, which is the check that nimkit and the
#            renderer still agree. Needs GTK's headers, not a display.
#   just test              all of them
#   just test nim tircparse    one Nim file
[doc('run a suite: all nim web desktop')]
test suite="all" *args:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    shift
    case "{{suite}}" in
        all)     just test nim && just test web && just test desktop ;;
        nim)     just _nim-test "$@" ;;
        web)     just _nim-js
                 just _app-js
                 "{{tc}}" exec -- bash -euo pipefail -c '
                     cd nim
                     nim js -d:nodejs --hints:off --path:../src --path:. \
                         --out:../build/web/tcrypto.js web/tcrypto.nim'
                 node build/web/tcrypto.js
                 node nim/web/test/smoke.js build/web/frq_core.js
                 node nim/web/test/session.js
                 exec python3 nim/web/test/serve.py ;;
        desktop) just _desktop ;;
        *)       echo "usage: just test [all|nim|web|desktop]" >&2; exit 1 ;;
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

# The web bundle: the page in web/, and the app compiled beside it.
#
# Copied rather than built into: web/ is source, and build/web is what a
# server serves — `just run web` here, and the image `.modal/web/Dockerfile`
# makes for the deployment.
[private]
_web-bundle:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    rm -rf build/web
    mkdir -p build/web
    cp -r web/. build/web/
    just _app-js
    # No client-metadata.json here: `tools/webserve.py` answers it from the
    # host each request arrives at, since its `client_id` has to equal that
    # URL. Served from `just run web` it cannot complete a Bluesky sign-in
    # unless the host is loopback -- an authorization server will not fetch
    # metadata over http from anywhere else. Guest works everywhere.
    echo "built build/web"

# The app for a page: the core, its renderer and nimkit's web backend, as one
# script. The main module lives under `nim/web`, and Nim resolves
# command-line search paths from that directory. `../src` is the shared tree
# and `.` is the web tree; the later path wins, so every module under
# `nim/web/frq` shadows the one beside it in `nim/src/frq`. Thus `frq/conn` is
# a queue the host fills rather than two socket threads, and the shared code
# above them never learns which host it is on.
[private]
_app-js:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    out="{{root}}/build/web"
    mkdir -p "$out"
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        nim js -d:release --hints:off \
            --path:../src --path:. --out:"'"$out"'/frq.js" web/frq_app.nim
        printf "built %s (%s)\n" "'"$out"'/frq.js" \
            "$(gzip -9c "'"$out"'/frq.js" | wc -c | awk "{printf \"%d KB gzipped\", \$1/1024}")"'

# The core alone as JavaScript, for the node tests: the same seam the page
# uses, with no renderer and no DOM.
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
            --path:../src --path:. --out:"'"$out"'/frq_core.js" web/frq_web.nim
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

# The desktop app, as one binary. nimkit's GTK backend takes its flags from
# pkg-config, so GTK's headers are all it needs from the host.
[private]
_desktop:
    #!/usr/bin/env bash
    set -euo pipefail
    cd "{{root}}"
    mkdir -p build
    exec "{{tc}}" exec -- bash -euo pipefail -c '
        cd nim
        nim c -d:release --hints:off --out:"'"{{root}}"'/build/frq" kit/frq_desktop.nim
        echo "built '"{{root}}"'/build/frq"'
