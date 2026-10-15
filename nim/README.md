# The Nim core

The program. It owns the state, the screens, the IRC connection and the
message signing, and the widget tree the screens emit is painted in Nim too:
`kit/` walks it into nimkit widgets, on GTK or in a page.

```
src/frq_core.nim        the C ABI: every exported symbol, and nothing else
src/frq/ui.nim          the widget tree, in the screens' own tag vocabulary
src/frq/cells.nim       every piece of state the screens read
src/frq/reducer.nim     every event they can send, and what it does
src/frq/model.nim       what a message and a room are
src/frq/rooms.nim       the list and the read marker
src/frq/members.nim     who is in a channel, and what the server says of them
src/frq/conn.nim        the socket, the TLS, the line framing
src/frq/ircparse.nim    the IRC wire format
src/frq/handshake.nim   CAP and the SASL exchange inside it
src/frq/atproto.nim     handle → DID → PDS → session
src/frq/crypto.nim      OpenSSL, bound: SHA-256 and Ed25519
src/frq/msgsig.nim      signing a mutation so freeq will accept it
src/frq/emoji.nim       1,884 emoji — generated, see below
src/frq/glyphs.nim      a line split into words and pictures
src/frq/clock.nim       server time in the reader's own zone
src/frq/store.nim       what survives a restart
src/frq/screens/        connect, chats, chat, discover, settings

kit/frqkit/render.nim   the tag vocabulary, as nimkit widgets, keyed
kit/frqkit/theme.nim    the palette, as a GTK CSS sheet and a web one
kit/frq_desktop.nim     the GTK host, built as ../build/frq
web/frq/                the browser's conn, store and crypto, by search path
web/frq_app.nim         the browser app: the seam, the renderer, nimkit's DOM
web/frq_web.nim         the seam alone (`globalThis.frq`), for the node tests
vendor/nimkit/          nimkit, vendored from nandi-conda/webby, with frq's
                        additions; GTK 3 and web backends, no Android
```

`nim.cfg` puts `vendor/nimkit` and `kit` on the search path for every compile
here. The core and its tests import neither; they are there so no recipe has
to spell them out. Changes to nimkit are made in `vendor/nimkit` — it is frq's
copy now, and the additions (pictures, wrapping rows, the caret, `reveal`,
`onFollow`, `onWindowSize`, GTK's bottom-up `resizeUp`) are not upstream.

## The ABI

The app no longer goes through it: the desktop links the core directly and
the page calls `globalThis.frq`. It still builds, as `just build lib`, and
`frq_ui_demo` in it is what the desktop's `FRQ_DEMO=1` opens on.

Strings in, strings out, and JSON where the answer is not a single string —
deliberately, against a struct-based ABI: a struct means both sides agreeing
on a memory layout, and a field added later is a version skew that segfaults
instead of failing.

Two rules, both of which cost a segfault to rediscover:

* Every string the core returns is the **caller's** to free, with `frq_free`.
  Nim's allocator is not the caller's.
* `frq_init` exists and does nothing. It used to call `NimMain`, and on Linux
  `--app:lib` already runs the module initialisers from a library constructor
  — so calling it again ran every module's top-level code a second time, which
  for `conn.nim` meant `open()` on channels that were already open.

## Things that will bite

* **Nothing is shared with the socket threads.** There are two — one reader,
  one writer — and they speak only in channels. `recvLine(timeout)` does not
  time out on a TLS socket, so a single thread cannot both wait for the server
  and notice what the client wants to say.
* **`--mm:orc`, not refc.** refc gives each thread its own GC heap, so the
  `Socket` the two threads share is a ref from another heap and dereferencing
  it segfaults.
* **Every intra-package import says `frq/…`.** `import conn` and
  `import frq/conn` name the same file by two paths and Nim compiles it twice,
  giving two sets of globals and two states.
* **`emoji.nim` is generated.** It was `tools/emoji2nim.py` reading the
  ClojureDart catalogue, which is gone; regenerating it now means going back to
  Unicode's `emoji-test.txt` and filtering to what the Twemoji pack draws.
* **The crypto is bindings, not implementations.** `crypto.nim` is OpenSSL
  through EVP. The RFC 8032 vectors in `tests/tcrypto.nim` check that this
  drives it correctly — the seed in the right place, the one-shot signing form,
  the bytes out in the right order — and not that Ed25519 is implemented
  correctly, which is OpenSSL's problem.

```bash
just test nim              # the whole suite
just test nim tircparse    # one file
just test web              # the JavaScript build, under node
just test desktop          # the GTK app compiled: nimkit and the renderer agree
just build lib             # libfrqcore.so into build/nim
```

## What is not here

`frq.replies` was never ported and went with the ClojureDart: asking freeq
what a collapsed msgid was, for a reply pointing at a line that arrived
already collapsed. It had no screen in this app to appear on, and the chip
says "an earlier message" where that happens.

`frq.profile` came back — recovered from the commit that deleted it and
ported, since a face that opens nothing is worse than no face.

The emoji picker, the lightbox and the profile card all have screens — the
picker under the message it is for, the lightbox as a panel over the
conversation — so the 🙂 chip and clicking a picture both do what they look
like they do.

Untested against a real account: nobody has watched freeq accept a SASL
challenge response or a signature. The shapes are checked and the curve is
OpenSSL's, but the server has not said yes.
