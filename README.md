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
src/frq/irc.jolt     IRC over TLS or TCP: parser, reader thread, JOIN/PRIVMSG/PING
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
* **Guest identity only.** No AT Protocol SASL, no OAuth, no credential gates,
  no E2EE — the parts of freeq that need crypto are exactly the parts left out.
* **No scrollback trimming, avatars, reactions, threads, or calls.**
* Message lists are keyed vboxes; glimmer-vidya has no `:listbox` yet.
