# `web`

    modal run .modal/web/container.py
    just modal web

Defined by `container.toml`; `../_loader.py` is what reads it, and
its comments are the spec.
Built on `debian:13-slim`.

No nix, and that is the point of this container rather than an
incidental fact about it. The build is `tools/build-web.sh`, which
gets its Flutter, its JDK and its Clojure CLI from
`tools/toolchain.sh` -- three tarballs pinned by sha256 and unpacked
into a directory. So the image build is one `apt-get install` of
curl, git, rsync, tar and the two unarchivers, and everything that
used to happen before a line of Dart was compiled -- warming a
devShell, printing its environment, caching that against flake.lock,
copying a nix closure back to a volume afterwards -- does not happen
at all. The toolchain lands on the volume and the second run finds
it there.

The `dev` container beside it works the same way now, and so does a
laptop: one script, one pinned set of tarballs, and whatever the
host has to bring for a given target -- GTK and a C++ toolchain for
the desktop build, Google's command-line tools for the APK.

Same incremental shape as before -- the working tree, the generated
Dart under `flutter/lib/cljd-out` and Flutter's caches live on the
`devshell` volume, under `frq-web/` so the desktop
container's directory beside it is untouched. None of them is copied
in from the laptop: a checkout's copy of the compiler's output is
not this container's, and overwriting the volume's with it is how an
incremental build stops being one.

One build mode, not two. A `fast` mode (dart2js -O1, no icon
tree-shaking, no service worker) measured 52.5s against the release
build's 49.8s on the same source change, so what it bought was a
bigger bundle. `--no-wasm-dry-run` is the flag that did pay, and it
is in the one build there is.

Runs as a Sandbox on a real VM (kernel 6.x, not gVisor). The command
is the sandbox's own process, so it dies when the command exits.

To look at what it built, ask for the serve action -- `[network]
ports` tunnels 8080 out, and the URL is printed once the sandbox is
scheduled:

    modal run .modal/web/container.py \
      --command 'cd /devshell/frq-web && tools/build-web.sh serve 8080'

That blocks until you Ctrl-C it, and it bills until you do.

## It compiles; it does not start

dart2js links the whole app -- `main.dart.js` is 3.6MB and has
`frq`, `irc`, `atproto` and `handshake` all through it, so the
`dart:io` imports under `flutter/src` are not the wall they look
like. What stops it is the first line of `main`:
`getApplicationDocumentsDirectory` is a platform channel, path_provider
ships no web implementation, and the channel with no handler behind it
throws `MissingPluginException`. `main` awaits that before installing
`frq.io.dart`, so no widget is ever built and the page stays white.

That is the seam doing its job rather than a build problem. The fix is
a `frq.io.web` behind `frq.io` -- the browser's answer for a private
file is IndexedDB or localStorage, not a directory -- and `main`
choosing it the way `flutter/src/frq/main.cljd` chooses the Dart one
now. `frq.net.web` is the next one after it, for the same reason: a
browser has no raw socket, so the IRC connection wants a WebSocket.

## Serving it

`serve.py` is the other half: a Function that mounts the same volume
and hands out `flutter/build/web`, so a rebuild in the Sandbox is
picked up by the next cold start with nothing redeployed.

    modal deploy .modal/web/serve.py

`[network] ports` tunnels 8080 out of the Sandbox as well, for the
case where you want the build and the server to be one process.
