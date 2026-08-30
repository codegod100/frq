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
src/frq/media.jolt   image links: spot them, fetch them once, cache on disk
src/frq/clock.jolt   the reader's own zone, twelve-hour times, day headings
src/frq/irc.jolt     IRC over TLS or TCP: parser, reader thread, SASL, PRIVMSG
src/frq/state.jolt   the ratoms every screen reads, and `apply-msg!`
src/frq/app.jolt     the screens
```

## Tracing

`FRQ_TRACE=1` prints every IRC line sent and received to stderr, which on
Android is logcat.

## Running

`libvidya` from Vidya's Rust/egui backend, then the app:

```bash
just lib
just run
```

`just run` is `jolt -M:frq` with `LD_LIBRARY_PATH` pointed at the built
library. It connects to `irc.freeq.at:6697` over TLS and joins `#test`. Untick
TLS on the connect screen (or point it at `127.0.0.1`) for a local server's
plain listener:

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

## Android

An APK with two shared libraries and no Java: `libvidya.so` (vidya's Rust/egui
C ABI, which owns the event loop as the NativeActivity's own library) and
`libjoltapp.so` (frq compiled to a Chez boot image). Both native halves come
from the vidya checkout; only the boot image is frq's.

```bash
./android/build-apk.sh run      # build, install, launch on a connected device
./android/build-apk.sh log      # logcat, filtered
```

Needs what vidya's Android build needs — SDK, NDK r29, and a cross-built Chez
in `~/.cache/vidya-chez-android`.

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
* Inline previews for PNG links, fetched once and cached under
  `$XDG_CACHE_HOME/frq/media`; click one to see it full size
* Join/part notices, DMs bucketed under the sender's nick
* Discover list, search over buffers, disconnect
* The rooms you have opened, remembered across runs and listed in the order
  you last used them (`$XDG_CONFIG_HOME/frq/channels.edn`)
* Conversations listed most recently opened first
* Bluesky avatars beside the sender, resolved from the DID freeq tags each
  message with

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
* **No scrollback trimming, reactions, threads, or calls.**
* A sent line waits up to 200ms for the reader thread to flush it.
* Message lists are keyed vboxes; glimmer-vidya has no `:listbox` yet.
