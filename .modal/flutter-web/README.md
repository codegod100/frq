# `flutter-web`

    modal run .modal/flutter-web/container.py
    just modal flutter-web

Defined by `container.toml`; see `../spec.md` for the keys.
Built on the published `arch-nix` image.

`flutter-dev` with the Linux target swapped for the web one: the same
`clojure -M:cljd compile` over the same `flutter/src` and `common/`,
then dart2js instead of CMake and Ninja. Same incremental shape --
the working tree and Flutter's caches live on the `devshell` volume,
under `frq-flutter-web/` so the desktop container's directory beside
it is untouched.

Runs as a Sandbox on a real VM (kernel 6.x, not gVisor). The command
is the sandbox's own process, so it dies when the command exits.

To look at what it built, ask for the serve action -- `[network]
ports` tunnels 8080 out, and the URL is printed once the sandbox is
scheduled:

    modal run .modal/flutter-web/container.py \
      --command 'cd /devshell/frq-flutter-web && nix develop /app#flutter-web --command just -f /devshell/frq-flutter-web/justfile flutter-web serve'

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

    modal deploy .modal/flutter-web/serve.py

`[network] ports` tunnels 8080 out of the Sandbox as well, for the
case where you want the build and the server to be one process.
