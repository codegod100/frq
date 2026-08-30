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
src/frq/atproto.jolt handle → DID → PDS → session, and the SASL payload
src/frq/irc.jolt     IRC over TLS or TCP: parser, reader thread, SASL, PRIVMSG
src/frq/state.jolt   the ratoms every screen reads, and `apply-msg!`
src/frq/app.jolt     the screens
```

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

Guest is the default. The **Bluesky** tab on the connect screen takes a handle
and an [app password](https://bsky.app/settings/app-passwords) and signs in
through AT Protocol:

1. `com.atproto.identity.resolveHandle` turns the handle into a DID
2. the DID document (PLC directory, or the domain for `did:web`) gives its PDS
3. `com.atproto.server.createSession` mints a session token there
4. freeq's SASL `ATPROTO-CHALLENGE` carries that token as `method:
   "pds-session"`, with the server's own nonce echoed back so it cannot be
   replayed elsewhere

The app password goes to the user's own PDS and nowhere else — freeq is handed
only the token, and verifies it by asking that same PDS. It is not written to
disk, and is dropped from memory once the session exists.

A refused sign-in is reported and the connection continues as a guest.

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
* Join/part notices, DMs bucketed under the sender's nick
* Discover list, search over buffers, disconnect

## Limits

* **TLS and plain TCP only** — no WebSocket, no iroh. On Android, plain only.
* **App-password sign-in only.** No OAuth broker, no `did:key` signing, no
  credential gates, no E2EE. Sign-in needs TLS, so it is desktop-only.
* **No scrollback trimming, avatars, reactions, threads, or calls.**
* Message lists are keyed vboxes; glimmer-vidya has no `:listbox` yet.
