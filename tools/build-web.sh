#!/usr/bin/env bash
# The Flutter web build: one `clojure -M:cljd compile` over `flutter/src` and
# `common/`, then `flutter build web` over what that generated.
#
# A shell script and not a `just` recipe in a devShell, because this is the
# one target that needs nothing from the host — no JDK of the machine's, no
# GTK, no Android SDK, no nix. `tools/toolchain.sh` fetches the three tarballs
# it does need, and everything below runs out of `.toolchain/`. The container
# in `.modal/web/` runs this same file; `just build web` is a
# wrapper around it.
#
#   tools/build-web.sh                      build build/web
#   tools/build-web.sh serve 8080           build it and serve it
#
# The entry point is `frq.main-web`, not `frq.main`: path_provider has no web
# implementation, so the `getApplicationSupportDirectory` that `frq.main`
# awaits throws MissingPluginException before any widget is built. The web
# entry installs `frq.io.web` — localStorage behind the same seam — and awaits
# nothing.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-build}"
port="${2:-8080}"

case "$action" in build|serve) ;; *)
    echo "usage: build-web.sh [build|serve] [port]" >&2; exit 1 ;;
esac

# One build, and it is the release one. There was a `fast` mode here for a
# while — dart2js at -O1, no icon tree-shaking, no service worker — on the
# theory that the edit-compile loop should not pay for the bundle it ships.
# Measured on this program it pays for almost nothing: -O1 came out at 52.5s
# against release's 49.8s on the same source change, because what dart2js
# spends its time on here is reading and linking the whole program, not
# optimising it. A second bundle, twice the surface to reason about and a
# megabyte more to serve, for noise. If a future dart2js changes that, the
# flags to reach for are `--optimization-level=1`, `--no-tree-shake-icons`
# and `--no-source-maps`, and the number to beat is written down above.
#
# `--no-wasm-dry-run` is the one that did pay: 52.0s against 55.7s, about 6%,
# for skipping a dry-run compile of the whole program against the wasm
# backend that can never succeed here. `frq.io.web`, `frq.net.web`,
# `frq.oauth.web` and three more are `dart:html`, which wasm does not
# support and which is the entire reason those namespaces exist. The build
# was being told, at whole-program cost, something the source already says.
build_flags=(--release --no-wasm-dry-run)

eval "$("$root/tools/toolchain.sh" env)"
cd "$root/flutter"

# The web target is off in a checkout created for Android and Linux.
# `flutter/web/` itself IS committed, unlike the Android and Linux runners:
# the OAuth client keeps a script of its own beside the bundle (see
# web/frq_dpop.js), and a directory `flutter create` regenerates is no place
# to keep one.
#
# Stamped, because `flutter config` is a Dart VM start and a settings-file
# rewrite for an answer that cannot change under us — this is the only thing
# that sets the flag, and the toolchain directory is already where this build
# remembers what it has done.
if [ ! -e "$FRQ_TOOLCHAIN/.web-enabled" ]; then
    flutter config --enable-web >/dev/null || true
    touch "$FRQ_TOOLCHAIN/.web-enabled"
fi

# `frq.main-web` and not `frq.main`: the compile walks out from the namespace
# it is given, which is what keeps `dart:html` in the web build and out of the
# other two. `flutter/lib/main_web.dart` is the one-line export beside the
# generated `main.dart` that -t points at.
#
# `-Sdeps` with an explicit local repo rather than ~/.m2, for GITLIBS' reason:
# the JVM will not look where HOME says.
clojure -Sdeps "{:mvn/local-repo \"$FRQ_M2\"}" -M:cljd compile frq.main-web

flutter build web -t lib/main_web.dart "${build_flags[@]}"
echo "built $PWD/build/web ($(du -sh build/web | cut -f1))"

if [ "$action" = serve ]; then
    echo "serving $PWD/build/web on :$port"
    # Dart's own file server, out of the toolchain, because the toolchain is
    # the whole dependency list: reaching for python3 here would put a fourth
    # language on the list of things a machine must already have to serve a
    # directory.
    #
    # --bind 0.0.0.0 and not loopback: in the container this is behind a Modal
    # tunnel, and a server bound to 127.0.0.1 is one the tunnel cannot reach.
    exec dart "$root/tools/serve-dir.dart" build/web "$port"
fi
