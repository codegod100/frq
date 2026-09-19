# frq

A **[freeq](https://github.com/codegod100/freeq)** client written in
**[ClojureDart](https://github.com/tensegritics/ClojureDart)**, painted by
Flutter — one set of screens on Android, on the Linux desktop and in a browser.
See [flutter/README.md](flutter/README.md).

It is a proof of concept port of [sleek](../sleek), which is the same client in
Rust against egui directly. The screens are sleek's — connect, chats, chat,
discover, settings, under a tab bar — but each is hiccup over the widget tags
`frq.hiccup` translates into Flutter, and state lives in atoms instead of an
`AppState` struct.

Source lives in three trees:

```
common/  .cljc  portable: the screens, the state, the protocol — no dart:
flutter/ .cljd  the Flutter half, and the host's answers — flutter/README.md
nim/     .nim   the portable logic as a native library — nim/README.md
dart/    .dart  the binding to it, and not a Flutter package — dart/README.md
```

The first two are the client as it runs today. `nim/` is where the logic under
the screens is moving, a module at a time, behind a C ABI; `dart/` is what
calls it. One module has made the trip so far and nothing imports it yet — see
`nim/README.md` for what is wired up and what is not.

What `common/` needs of the host it asks `common/frq/io.cljc` for — the seam,
named once and answered per target: `frq.io.dart` on Android and the desktop,
`frq.io.web` in a browser.

```
common/frq/io.cljc            the seam: filesystem, environment, config dir, clock
common/frq/clock.cljc         IRCv3 time tags → the reader's own zone
common/frq/store.cljc         the saved sign-in, mode 600 in the config directory
common/frq/emoji.cljc         the picker's catalog: every emoji and its name
common/frq/rooms.cljc         the rooms this client has been in, and their order
common/frq/cells.cljc         the atoms every screen reads
common/frq/screens/           connect, chats, chat, discover, settings
common/frq/irc/parse.cljc     the IRC line parser, tags and all
common/frq/irc/handshake.cljc SASL, driven from shared code
common/frq/atproto/core.cljc  handle → DID → PDS → session, and the SASL payloads
common/frq/oauth/core.cljc    the broker flow, as far as it is portable
common/frq/msgsig.cljc        message signatures
flutter/src/frq/main.cljd     the entry point: installs the host, then starts
flutter/src/frq/hiccup.cljd   the widget tags, as Flutter
flutter/src/frq/net/          sockets: dart:io on native, WebSocket on the web
flutter/src/frq/io/           the host's answers to the seam
```

There used to be a third tree, `src/`, and another runtime under it: jolt, with
[glimmer](https://github.com/jolt-lang/glimmer) components painted by
**libcosmic** in a desktop window and by `libjolttui` in a terminal, plus an
AV media plane over MoQ. It is gone. Flutter is the only frontend now, which is
why `common/` no longer carries `#?(:jolt ...)` reader conditionals and why the
calls, terminal and `nix run .#frq` sections that used to be here are not.

## Tracing

`FRQ_TRACE=1` prints every IRC line sent and received to stderr, which on
Android is logcat.

## Running

```bash
just flutter-desktop run     # the Linux window
just apk run                 # onto a connected Android device
just flutter-web serve       # a browser, on :8080
```

Every recipe lives in the `justfile` itself. The two that need a toolchain from
Nix re-enter `nix develop` and come back to the same recipe, so `just
flutter-desktop` and `nix develop .#flutter-desktop --command just
flutter-desktop` are one code path rather than two. `just flutter-web` needs no
Nix at all: `tools/toolchain.sh` fetches Flutter, a JDK and the Clojure CLI by
sha256, which is what lets `.modal/flutter-web/` run the same script on a plain
Debian image.

All three are one `clojure -M:cljd compile` over `flutter/src` and `common/`,
and differ only in which Flutter target runs afterwards.

frq connects to `irc.freeq.at:6697` over TLS and joins `#test`. Untick TLS on
the connect screen (or point it at `127.0.0.1`) for a local server's plain
listener:

```bash
cargo run --release --bin freeq-server        # in the freeq checkout
```

A browser has no TCP, so the web build wants a WebSocket URL in the Server
field — `wss://irc.freeq.at/irc`. And Bluesky sign-in only completes on
`localhost`, because that is the one origin freeq's auth broker will redirect
back to: `just web-local` is what serves the Modal-built bundle there.

## Signing in

Three modes on the connect screen.

**Bluesky** (OAuth, the default way in) follows sleek's flow: frq binds a
loopback port, puts it in `return_to`, and opens
`auth.freeq.at/auth/login?handle=…`. The broker runs the OAuth dance with the
PDS and redirects back to that port with the handoff in the URL *fragment*, so
it never reaches a server as a query string. The page frq serves there has one
job: POST the fragment back to itself. What comes back is a single-use SASL
`web-token` and a durable `broker_token`; later connections mint a fresh token
from the durable one at `/session` and skip the browser.

The durable token is saved to `$XDG_CONFIG_HOME/frq/session.edn` (mode 600) so
a restart resumes without one, along with the handle and nick it belongs to —
and it connects on its own at launch when one is there.
The web-token beside it is single-use and deliberately not saved. A token the
broker no longer honours is dropped — from disk and memory — and the browser
flow runs once more, rather than failing the same way on every Connect.

**App password** signs in without a browser, straight to the user's own PDS:
`resolveHandle` → DID → PDS from the DID document → `createSession`. The
password goes to that PDS and nowhere else, is never written to disk, and is
dropped once the session exists.

Either way freeq sees only a token. The SASL mechanism is
`ATPROTO-CHALLENGE` in both cases — `method: "web-token"`, which the server
resolves through its own token store, or `method: "pds-session"` with the
server's nonce echoed back so the token cannot be replayed elsewhere.

A refused sign-in is reported and the connection carries on as a guest.

## Targets

Three, from one compile, and what separates them is the host half rather than
the screens.

**Android** and **the Linux desktop** are both `dart:io` underneath:
`frq.io.dart` answers the seam, `frq.net.dart` opens a real TCP or TLS socket.
`frq.io.dart/write-private-file!` is the one place that asks which of the two it
is on (`Platform.isAndroid`), because assuming cost a token its file mode.

**The web** is not: a browser has no TCP and no filesystem, so `frq.net.web`
carries an IRC WebSocket and `frq.io.web` keeps the seam's files in local
storage. Bluesky sign-in works there only on `localhost` — see Running.

What carries over untouched is `common/` — the screens, the state, the parser,
the protocol. See the two trees at the top.

## What the PoC covers

* TLS (`:6697`, out of `dart:io`) or plain TCP (`:6667`); a WebSocket on the web
* Guest connect (`NICK`/`USER`), `001` welcome, `PING`/`PONG` keepalive
* Auto-joins `#test` on `irc.freeq.at`
* Join channels, channel buffers with unread counts, send and receive `PRIVMSG`
* Backlog on join, and `CHATHISTORY` for the channels freeq restores instead
* Twelve-hour timestamps from the server's own clock, with a heading wherever
  the day changes
* A chip above a reply quoting what it answers, and a click that goes there;
  ↩ beside a sender to answer them, with `+draft/reply` on the way out
* Emoji reactions: colour pills under a message, ☺ beside the sender to open a
  picker over every emoji the backend can draw (popular first, then Unicode's own
  groups, searchable by name), and a second click on a pill to take yours off
  — sent as `TAGMSG`, and restored from the server's own tally when the
  backlog comes back
* Inline previews for PNG links, fetched once and cached under
  `$XDG_CACHE_HOME/frq/media`; click one to see it full size
* Ctrl+V in the draft attaches the picture on the clipboard: it is previewed
  under the box and uploaded to freeq's media endpoint while you write the line
  it goes with, and only on the way out does it become the link — which is the
  whole of what sending an image over IRC means. The draft itself is never
  written into. Text pastes as text, as it always did: the picture path is the
  keystroke the field had no text to answer with
* Join/part notices, DMs bucketed under the sender's nick
* Discover list, search over buffers, disconnect
* The rooms you have opened, remembered across runs and listed in the order
  you last used them (`$XDG_CONFIG_HOME/frq/channels.edn`)
* Conversations listed most recently opened first
* Bluesky avatars beside the sender, resolved from the DID freeq tags each
  message with

## Limits

* **TLS and plain TCP only** — no WebSocket, no iroh. On Android, plain only.
* **No `did:key` signing, no credential gates, no E2EE.**
* **Only the broker token is persisted**, and only for OAuth. An app-password
  sign-in is not remembered.
* **Previews are PNG only.** The link is left in place either way.
* **Nothing evicts the media cache.**
* **No calls.** The AV signaling is still in the screens, but the media plane
  it drove was `libjoltmoq` under the retired jolt half — Opus, H.264, V4L2 and
  ALSA, none of which crosses to Flutter. The Call controls are wired to
  actions no target installs. Flutter's camera and audio plugins are the way
  back in, and that is its own project.
* **Attaching a picture needs a sign-in.** The upload is filed under the DID
  of a live session, so a guest cannot make one. It also shares nothing to your
  PDS and posts nothing to Bluesky — those fields are opt-in and this client
  does not send them.
* **No scrollback trimming or threads.**
* A sent line waits up to 200ms for the reader to flush it.
