# frq

A **[freeq](https://github.com/codegod100/freeq)** client written in
**[jolt](https://github.com/jolt-lang/jolt)**, as
[glimmer](https://github.com/jolt-lang/glimmer) components painted by
**[Vidya](https://tangled.org/nandi.uk/vidya)**/egui.

It is a proof of concept port of [sleek](../sleek), which is the same client in
Rust against egui directly. The screens are sleek's — connect, chats, chat,
discover, settings, under a tab bar — but each is hiccup over glimmer's widget
tags rather than immediate-mode drawing code, and state lives in ratoms instead
of an `AppState` struct.

```
src/frq/atproto.jolt handle → DID → PDS → session, and the SASL payloads
src/frq/oauth.jolt   the broker flow: login URL, loopback capture, /session
src/frq/store.jolt   the saved sign-in, mode 600 in the config directory
src/frq/avatars.jolt profile pictures, by DID or handle
src/frq/profile.jolt who someone is: the Bluesky profile behind a nick
src/frq/media.jolt   image links: spot them, fetch them once, cache on disk
src/frq/upload.jolt  a pasted picture to freeq's media endpoint, as multipart
src/frq/av.jolt      calls: the signaling, and a handle on the media plane
src/frq/clock.jolt   the reader's own zone, twelve-hour times, day headings
src/frq/emoji.jolt   the picker's catalog: every drawable emoji and its name
src/frq/irc.jolt     IRC over TLS or TCP: parser, reader thread, SASL, PRIVMSG
src/frq/state.jolt   the ratoms every screen reads, and `apply-msg!`
src/frq/app.jolt     the screens
```

## Tracing

`FRQ_TRACE=1` prints every IRC line sent and received to stderr, which on
Android is logcat.

## Running

The app:

```bash
just run
```

Every recipe lives in the `justfile` itself. Each one that runs frq re-enters
`nix develop` and comes back to the same recipe, so `just run` and
`nix develop --command just run` are one code path rather than two. Nothing has
to be installed for that but Nix.

`just run` is `jolt -M:frq` inside `nix develop`, with `LD_LIBRARY_PATH`
pointed at the shell's `JOLT_NATIVE_LIB` — the flake's build of
[jolt-native](https://gitlab.com/nandithebull/jolt-native), which is both
shared objects this client loads: `libvidya`, the retained-tree ABI glimmer
paints through, and `libjoltmoq`, the AV media plane. The source frq runs is
the working tree; everything under it is built rather than fetched, at the revs
`flake.lock` names. Nothing has to be installed but Nix, and no jolt-native
checkout beside this one.

The APK is the other half of that: it takes the two libraries out of
jolt-native's *release* instead, by the digests in `nix/android.nix`, because a
derivation's inputs have to be fetchurl. `just bump` moves those pins — and
deps.edn's glimmer-vidya sha — to the latest release at once, and
`just bump v0.1.2` to a named one.

`jolt` on its own does not work in this tree: `deps.edn` names both libraries
under `:jolt/native`, so every invocation loads them before it reads a line and
dies if the loader cannot find them. `just repl` is that jolt with the shell
under it — a REPL, or `just repl nrepl-server` for an editor.

frq connects to `irc.freeq.at:6697` over TLS and joins `#test`. Untick TLS on
the connect screen (or point it at `127.0.0.1`) for a local server's
plain listener:

```bash
cargo run --release --bin freeq-server        # in the freeq checkout
```

## In a terminal

The screens are hiccup over glimmer's reconciler, and the reconciler does not
know what is under it — so the same tree paints into a terminal through
jolt-native's `libjolttui`, which exports libvidya's retained-tree ABI over a
grid of cells instead of a GPU window.

It is the client, not a preview of it. `frq.app/start!` is what a launch does —
the saved settings, the rooms this client has been in, the sign-in that
connects itself — and `src/frq/tui.jolt` hands it the terminal's timers instead
of the window's. Nothing in `frq.app` changed.

```bash
nix run .#tui                             # or: just tui
just tui --headless --cols=90 --rows=60   # one screenshot on stdout
just tui --headless --demo                # a buffer of its own, no server
just tui --headless --wait=9000           # long enough to have connected
just tui --headless --dump                # and the tree the library holds
```

The headless one is `tui_headless` — the same layout and the same painting with
the writer taken off the end — which is what a screenshot in a bug report or a
CI check should be. It paints once and prints, so `--wait=` is how long the
client is given first: the default is a picture of the connect screen, because
that is where a client is a moment after launch, and `--demo` fills a `#tui`
buffer for a screenshot that is not waiting on a server at all.

Logs go to stderr, which in a terminal session is the screen frq is painting.
Send them somewhere: `nix run .#tui 2>/tmp/frq.log`.

What a terminal has not got, frq does without: pictures, avatars and the
lightbox draw nothing, and calls are off — the media plane paints frames into
a texture, and there is no texture here.

The spacing is written in points, for a window, and a cell is about eight of
them across and sixteen down — so the backend is handed both numbers and each
prop is divided by the axis it measures. A gap of half a cell rounds to
nothing, which is what `:spacing 8` against a 16-point row is: thirteen
messages fit where rounding it up left room for two.

The two reserves in `src/frq/app.jolt` are the one thing a scale cannot
answer, because they are counted in rows of chrome rather than in lengths: a
window's row is 34 points and a terminal's is one cell. `chrome-row` is where
that is said, and `frq.tui` sets it.

`just tui` is `just run`'s two halves with the other backend under them: this
tree's source on the flake's everything-else, in the dev shell. jolt-native
carries both native libraries and both Jolt sides — glimmer-vidya for the
window, glimmer-tui for the terminal — so one input answers for either, and
nothing here needs a checkout beside the tree.

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

## Android

An APK whose native halves come from jolt-native's release and whose Jolt half
is frq's: `libvidya.so` (the Rust/egui C ABI, which owns the event loop as the
NativeActivity's own library), `libjoltmoq.so` (the media plane) and
`libjoltapp.so` (frq compiled to a Chez boot image, linked against both).

```bash
just apk run                    # build, install, launch on a connected device
just apk log                    # logcat, filtered
```

Needs nothing on the machine but Nix and an `adb`: the build is
[`nix/android.nix`](nix/android.nix), and the SDK, the NDK, the arm64 Chez
cross target and the OpenSSL the app carries are all built or fetched there.
`nix build .#apk` is the same thing without adb; on a machine with a remote
builder, hand it the store rather than a `builders` entry —
`FRQ_NIX_STORE=ssh-ng://eu.nixbuild.net just apk`, and see the header of
`nix/android.nix` for why.

TLS does not work there: jolt reaches OpenSSL through the dynamic loader, and
Android has no public `libssl` to load. The connect screen falls back to the
plain `:6667` listener on its own, which is why the plain transport is the raw
`socket`/`connect`/`send`/`recv` calls rather than jolt's `java.net.Socket`
surface — that surface does not work on Android either, while the syscalls do.

## What the PoC covers

* TLS (`:6697`, via jolt.mvn-http's OpenSSL bindings) or plain TCP (`:6667`)
* Guest connect (`NICK`/`USER`), `001` welcome, `PING`/`PONG` keepalive
* Auto-joins `#test` on `irc.freeq.at`
* Join channels, channel buffers with unread counts, send and receive `PRIVMSG`
* Backlog on join, and `CHATHISTORY` for the channels freeq restores instead
* Twelve-hour timestamps from the server's own clock, with a heading wherever
  the day changes
* A chip above a reply quoting what it answers, and a click that goes there;
  ↩ beside a sender to answer them, with `+draft/reply` on the way out
* Emoji reactions: colour pills under a message, ☺ beside the sender to open a
  picker over every emoji Vidya can draw (popular first, then Unicode's own
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
* Calls: a Call button opens one in a channel, a banner offers Join where
  somebody already has, and in one there is mute, deafen, video and leave. Mute
  and deafen are separate — a deafened microphone still carries your voice.
  Whoever turns a camera on appears as a tile; the self-view is labelled You
  and sits last, where it cannot push a face you are talking to off the row

## Calls

Signaling is IRC and lives here: `+freeq.at/av-start`, `av-join` and `av-leave`
go out as TAGMSGs and the server broadcasts `+freeq.at/av-state` back, which is
what actually moves this client's state — a press is optimistic, and the server
settles it. Losing a race to open a call (`start-collision`) is answered by
joining the call that won rather than by reporting an error, since the person
asked to be in a call in that room and there is one.

Media is not IRC and is not here. Audio and video ride MoQ — Media over QUIC —
through freeq's SFU, and that is `libjoltmoq`: Opus, H.264, capture and
transport, lifted out of sleek rather than written a second time in jolt.
`src/frq/av.jolt` is the whole of what frq says to it, and two of its rules
shape this side:

* **Nothing calls back.** Status and video are polled, drained by a timer that
  glimmer runs on the loop thread — the only thread allowed to touch a node.
* **A frame is borrowed.** The decoder's own buffer is handed to Vidya as a
  pointer and painted by an `:image` with a `:feed`. The pixels never become a
  jolt value and are never copied on this side, which is the only way thirty
  frames a second is affordable here.

The SFU is dialled once the server has minted a token, not when we ask to join:
a remote SFU refuses a connection without one, and the MoQ client then retries
in a loop that looks exactly like a hang.

## Limits

* **TLS and plain TCP only** — no WebSocket, no iroh. On Android, plain only.
* **No `did:key` signing, no credential gates, no E2EE.** Sign-in of either
  kind needs TLS, so it is desktop-only — the Android build connects as a
  guest.
* **Only the broker token is persisted**, and only for OAuth. An app-password
  sign-in is not remembered.
* **Previews are PNG only** — the tree backend's decoder reads no other
  format, and a fetch needs TLS, so the phone shows links. The link is left in
  place either way.
* **Nothing evicts the media cache.**
* **Calls are desktop-only.** `libjoltmoq` is not built for Android here, and
  the camera and microphone paths that are would still need the runtime
  permissions the APK does not ask for.
* **One call at a time**, which is the media plane's rule and the microphone's.
* **No call is offered in a DM** — freeq's AV signaling is a channel's.
* **Pasting a picture needs a sign-in and a desktop.** The upload is filed
  under the DID of a live session, so a guest cannot make one; and it is read
  off the clipboard through the ABI's `vidya_clipboard_image_png`, which
  arboard backs on desktop and nothing backs on Android. It also shares
  nothing to your PDS and posts nothing to Bluesky — those fields are opt-in
  and this client does not send them.
* **No scrollback trimming or threads.**
* A sent line waits up to 200ms for the reader thread to flush it.
* Message lists are keyed vboxes; glimmer-vidya has no `:listbox` yet.
