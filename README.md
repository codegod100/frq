# frq

A **[freeq](https://github.com/codegod100/freeq)** client written in **Nim**,
from the socket to the pixels. Nim owns the state, the screens, the IRC
connection and the message signing, and nimkit — a small retained-mode
toolkit, vendored — paints the widget tree they emit: as GTK 3 widgets on the
desktop, and as DOM in a browser.

It is a proof of concept port of [sleek](../sleek), which is the same client in
Rust against egui directly. The screens are sleek's — connect, chats, chat,
discover, settings, under a tab bar.

```
nim/src            the program: state, screens, IRC, signing
nim/web            the same program's host half for a browser, and its app
nim/kit            the renderer and the palette over nimkit, and the GTK host
nim/vendor/nimkit  the widget toolkit: GTK 3 and the DOM, behind one API
web/               the page, and the JavaScript that owns the socket
```

```
nim/src/frq/ui.nim          the widget tree, in the screens' own tag vocabulary
nim/src/frq/cells.nim       every piece of state the screens read
nim/src/frq/reducer.nim     every event they can send, and what it does
nim/src/frq/conn.nim        the socket, the TLS, the line framing
nim/src/frq/ircparse.nim    the IRC wire format
nim/src/frq/handshake.nim   CAP and the SASL exchange inside it
nim/src/frq/atproto.nim     handle → DID → PDS → session
nim/src/frq/crypto.nim      OpenSSL, bound: SHA-256 and Ed25519
nim/src/frq/msgsig.nim      signing a mutation so freeq will accept it
nim/src/frq/screens/        connect, chats, chat, discover, settings
nim/kit/frqkit/render.nim   the tags, as nimkit widgets, reconciled by key
nim/kit/frqkit/theme.nim    the palette, as a GTK sheet and a web one
nim/kit/frq_desktop.nim     the GTK host: the window, files, clipboard, uploads
nim/web/frq_app.nim         the browser host, compiled by `nim js`
```

There were other clients here. `src/` was jolt with a libcosmic window and
a terminal; `common/` and `flutter/src/` were ClojureDart, compiled for
Android, Linux and the web; `dart/` and `flutter/` were a Flutter renderer
over this same core through `dart:ffi`. All are gone. The web target went and
came back: not as wasm, which is what a browser without `dart:ffi` seemed to
want, but as `nim js` compiling the core and its renderer together.

## Running

```bash
just run desktop     # build build/frq and open the window
just run web         # build build/web and serve it on :8000
just test            # nim, web and desktop
just test nim        # the core alone, in about a second
```

`just build desktop|web|lib|core-js` builds without running; `lib` is the
core alone as `libfrqcore.so`, which still builds but which nothing in the
tree loads any more.

`tools/toolchain.sh` fetches Nim by sha256, and nothing else; there is no nix,
no JVM and no Flutter. The host brings `just`, a C compiler, OpenSSL, curl,
tar and Python 3, plus GTK 3 and pkg-config for the desktop and Node.js for
`just test web`. The Modal development environment installs that complete
host-side set, so an attached shell can run every command above without
additional setup.

A few switches, because a Wayland window cannot be clicked from a script:

```bash
FRQ_TRACE=1 just run desktop        # every line in and out
FRQ_AUTOCONNECT=1 just run desktop  # press Connect at startup (FRQ_NICK= sets the nick)
FRQ_DEMO=1 just run desktop         # open on a representative room, no server
FRQ_THEME=light just run desktop    # or dark; otherwise the desktop's own
```

frq connects to `irc.freeq.at:6697` over TLS and joins `#test`. Untick TLS on
the connect screen (or point it at `127.0.0.1`) for a local server's plain
listener:

```bash
cargo run --release --bin freeq-server        # in the freeq checkout
```

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

Two: the Linux desktop on GTK 3, and the web.

**The desktop** is one binary, `build/frq`, with the core linked in and
nimkit's GTK backend over it. **The web** is `build/web`: the page in `web/`,
and `frq.js` beside it — the same core and the same renderer compiled by
`nim js` over nimkit's DOM backend. The page's own JavaScript owns the socket,
the OAuth and the uploads. It has no app-password tab, because that wants a
blocking call to the reader's own PDS, and it keeps no broker token, because
`localStorage` is readable by every script the origin runs. It signs with
TweetNaCl (`web/nacl-fast.min.js`), since WebCrypto's Ed25519 is a Promise.

**Android** is the one that has not come back. It went with ClojureDart, and
would want nimkit's Android backend — dropped when nimkit was vendored — and
the core cross-compiled for its ABIs.

## What the PoC covers

* TLS (`:6697`) or plain TCP (`:6667`), out of Nim's `std/net`
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

* **TLS and plain TCP on the desktop, a WebSocket in the browser** — no iroh.
* **No `did:key` signing, no credential gates, no E2EE.**
* **Only the broker token is persisted**, and only for OAuth. An app-password
  sign-in is not remembered.
* **Previews are PNG only.** The link is left in place either way.
* **Nothing evicts the media cache.**
* **No calls.** The AV signaling is still in the screens, but the media plane
  it drove was `libjoltmoq` under the retired jolt half — Opus, H.264, V4L2 and
  ALSA. The Call controls are wired to actions no target installs. Bringing
  a media plane back is its own project.
* **Attaching a picture needs a sign-in.** The upload is filed under the DID
  of a live session, so a guest cannot make one. It also shares nothing to your
  PDS and posts nothing to Bluesky — those fields are opt-in and this client
  does not send them.
* **No scrollback trimming or threads.**
* A sent line waits up to 200ms for the reader to flush it.
