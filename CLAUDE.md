# Working in this repo

## The toolchain, and where builds happen

There is no nix in the build. `tools/toolchain.sh` fetches Nim as a
sha256-pinned tarball into `.toolchain/`, and every `just` recipe runs inside
the environment that script prints. The host brings a C compiler, OpenSSL,
curl, tar and python3 — GTK 3 and pkg-config for the desktop, and node for
`just test web`.

It used to carry Flutter (which carried Dart), a JDK, the Clojure CLI, a maven
repo and an Android SDK as well. Those were the Flutter renderer's,
ClojureDart's and the APK's, and all three are gone.

**Prefer Modal for a long build.** A cold toolchain plus a full GTK compile is
still a fair amount of laptop, and the containers in `.modal/` do it on a real
machine. `dev` builds the GTK desktop app — `just build desktop`, out of the
same toolchain:

```bash
just modal dev    # the incremental desktop build
```

The containers in `.modal/` are not a third source tree: they are CI config
that happens to live here, the way `.github/` would be. They run the very same
`tools/toolchain.sh`, which is why a plain Debian image is enough.

`modal app logs` is no substitute for watching that command: it resolves
deployed apps by name, not the ephemeral one a `modal run` creates, and carries
nothing until the Sandbox starts — the image build streams to the client and
nowhere else.

Two containers, and they are not the same kind of thing — which is why they
are not written the same way. `dev` is a build that ends, and is a
`container.toml` read by `_loader.py`: a sandbox with a volume, a toolchain
and a command that changes. `web` is a deploy, and is plain Modal in
`.modal/web/deploy.py`, because four constants and a `Popen` did not need a spec
file to be read before the file itself made sense.

`web` is a deploy: GitHub Actions builds `.modal/web/Dockerfile` into GHCR
(`.github/workflows/deploy.yml`), and
`modal deploy .modal/web/deploy.py` serves that exact tag at a URL,
building nothing. So `just build web` on a laptop and the thing
on the internet come from the same two commands, run in different places —
and a deploy is a pull rather than a compile.

The containers run as Modal **Sandboxes on a real VM** rather than under
gVisor: a real kernel, a working pty, and memory that is exactly what
`[resources] memory` asks for.

One thing this container is *not* representative of: `/etc/localtime` is a
regular file here rather than a symlink, so anything that reads the zone out
of its path sees nothing. That is a real deployment shape, not an artefact —
frq.clock handles it.

## Never pipe a long task through `tail`

`tail` and `head` do not emit anything until their input ends, so a build, a
test run or a deploy piped through one shows nothing at all until it is over —
and if it is killed or times out first, its output is lost with it. That is the
opposite of what you want from the commands that take longest.

Let them write to the terminal, or `tee` them if you want a copy to grep
afterwards:

```bash
modal run .modal/dev/container.py 2>&1 | tee /tmp/frq-build.log
```

Trim afterwards, on the file, where the whole run is still there to re-read.
The same goes for `grep` and `awk` in a live pipeline: they buffer when their
output is not a terminal, so pass `--line-buffered` / `fflush()` or watch the
file instead.

## FreeQ protocol and client reference

[`freeq-irc/freeq`](https://github.com/freeq-irc/freeq) is the repository for
the FreeQ server and its canonical React web client. Treat it as the reference
material for wire-level behavior and client-facing semantics when implementing
or changing this client — especially IRCv3 tags, typed actions such as
handoffs, and their companion messages. Keep this app's own visual language;
the reference defines the protocol and interaction contract, not a styling
dependency.

## The Nim core

`nim/` is the program. It owns the state, the screens, the IRC connection and
the signing, and now the pixels too: nimkit paints the widget tree it emits,
on GTK and in a page, so there is one language from the socket to the window.
Read `nim/README.md` before touching it.

The C ABI in `nim/src/frq_core.nim` still builds, as `just build lib`, though
nothing in the tree loads it any more — the desktop links the core directly.
Two rules it has, both of which cost a segfault to rediscover:

* Every string the core returns is the **caller's** to free, with `frq_free`.
  Nim's allocator is not the caller's.
* `frq_init` runs once before anything else.

The rule that used to be here said new Dart-side code is written in Dart
rather than ClojureDart. There is no Dart left either, but the reasoning it
rested on still holds for the next thing: logic goes in Nim, the platform goes
in the host — nimkit's backends, and the page's JavaScript in `web/` — and
neither is written in a third language because it is already open.

`just test nim` needs no GTK and no browser, which is most of the point: the
core is checkable in about a second. `just test web` drives the JavaScript
build of the same core under node, and `just test desktop` compiles the GTK
app, which is the check that nimkit and the renderer still agree.

There is no `common/` any more, and that rule went with it. It said a module
stays until there is a wasm build of the core, because a browser has no
dart:ffi. The premise was right and the conclusion was wrong: the answer was
not wasm but `nim js`, which compiles the same core — state, reducer, every
screen — to JavaScript that a page loads with a `<script>` tag.

So there is a web target again, `just build web`. What differs from the
desktop is only the host: `nim/web/frq/*.nim` shadows `nim/src/frq/*.nim` by
search path (`--path:../src --path:.`, resolved from `nim/web`; later wins),
so `frq/conn` is a queue a
WebSocket fills rather than two socket threads, `frq/store` is localStorage,
and `frq/crypto` signs through TweetNaCl rather than OpenSSL. The shared code above them
imports the same names either way and never learns which host it is on.
nimkit does the same one layer up: one widget API over a GTK backend and a DOM
one, so the renderer is written once. The two entry points are
`nim/kit/frq_desktop.nim` and `nim/web/frq_app.nim`.

## The source trees

```
nim/src            the program: state, screens, IRC, signing
nim/web            the same program's host half for a browser, and its app
nim/kit            the renderer and the palette over nimkit, and the GTK host
nim/vendor/nimkit  the widget toolkit: GTK 3 and the DOM, behind one API
web                the page, and the JavaScript that owns the socket
```

`nim/src/frq/ui.nim` builds a widget tree, a `ui.Node`;
`nim/kit/frqkit/render.nim` walks it into nimkit widgets, reconciling by key
so a repaint touches what changed rather than rebuilding the window. The
renderer knows the tag vocabulary and nothing else — no screens, no state, no
idea what "connect" means. If a feature ever needs a change on both sides, the
boundary is in the wrong place. One exception it makes on purpose: an entry
carrying a `rev` is patched in place, and a keystroke goes to the core through
`input` with no tree back, because a whole tree per keystroke was the typing
latency.

nimkit is a retained-mode widget toolkit, vendored into `nim/vendor/nimkit`
from [`nandi-conda/webby`](https://github.com/nandi-conda/webby)
(`framework/src` at `31482f9`) with its Android backend dropped. It has two
backends: GTK 3, where every widget is a real GtkWidget styled by CSS classes
named `nk-<cls>` and the flags come from pkg-config; and the web, under
`nim js`, as DOM and flexbox. frq has added to it — a `picture` (a URL or
bytes, fit and rounding, fetched and cached), wrapping rows (`wrapping`: a
GtkFlowBox, or flex-wrap), an entry's caret, `reveal` to scroll a widget into
view, `onFollow` for a scroll held at its end, `onWindowSize` — and fixed it
in two places. On GTK, ancestors are re-measured bottom-up after an add
(`resizeUp`), because GTK caches a container's height-for-width request mode.
On the web, a column's non-expanding children do not shrink and its expanding
ones start from their content's size, and a box with no padding of its own
leaves its class's padding standing.

Colours come from `nim/kit/frqkit/theme.nim`, never from the renderer: frq's
dark palette and flatkit's light one, written once as a GTK CSS sheet and once
as a web sheet. The desktop takes `FRQ_THEME=dark|light`, or else the
desktop's own; the page follows `prefers-color-scheme`.

There used to be more trees. `src/` was jolt and libcosmic; `common/` and
`flutter/src/` were ClojureDart, compiled for Android, Linux and the web; and
after them `dart/` and `flutter/` were a Flutter renderer over the core
through `dart:ffi`, painting with flatkit. All of them are gone. The APK went
with the ClojureDart and has not come back — it wants the core cross-compiled
for Android's ABIs — but the web target has, by a different road than the one
that was expected: `just build web`.

Two things the web build does not do, both of them written down where they
are done rather than only here. It has no app-password tab, because that
wants a blocking call to the reader's own PDS. And it does not keep a broker
token, because `localStorage` is readable by every script the origin runs.

It used to be three: it could not sign, because WebCrypto's Ed25519 is a
Promise and every signature here is wanted inline, so a signed-in reader was
refused every edit, delete and reaction. It signs now with TweetNaCl,
vendored as `web/nacl-fast.min.js` — synchronous, one file, no
bundler — and `nim/web/tcrypto.nim` checks it under node, since the Nim
suite builds for C and cannot see the browser's crypto at all.

Two modules were never ported and are gone rather than moved: `frq.profile`
(the Bluesky profile behind a nick) and `frq.replies` (asking freeq what a
collapsed msgid was). Neither had a screen in the Nim app to appear on.
