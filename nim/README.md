# The Nim core

The portable half of frq, as a native library the Dart side calls through FFI.

## Why this exists

`common/` is ClojureDart, compiled into every target. That works, and the
reason to move any of it is not that it is broken: it is that the logic under
the screens — the IRC wire format, the atproto flows, the message signatures —
is the part with the most rules per line and the least to do with Flutter, and
it is the part worth having in a language with a type checker and a test runner
that does not need a Flutter toolchain to run.

So the plan is a seam, not a rewrite-in-place. Each module moves one at a time:
the Nim implementation lands here with tests, the Dart binding lands in
`flutter/src/frq/core/`, and the ClojureDart original stays until the binding
is proven against it. Nothing is deleted on faith.

## What is here

```
src/frq_core.nim        the C ABI: every exported symbol, and nothing else
src/frq/ircparse.nim    the IRC wire format
tests/                  one per module, run by `just nim-test`
```

`src/frq_core.nim` is the only file that knows about C. Everything under
`src/frq/` is ordinary Nim with ordinary Nim types, so the tests test the logic
rather than the marshalling.

## The ABI

Strings in, strings out, and JSON where the answer is not a single string.

That is a deliberate choice against a struct-based ABI. A struct means the Dart
side and the Nim side have to agree on a memory layout, and every field added
later is a version skew that segfaults instead of failing. JSON costs a parse
per call, which is nothing against a network round trip, and it lets one side
gain a field without the other crashing.

Every function that returns a string returns memory the **caller must free**
with `frq_free`. Nim's allocator is not Dart's; a `free()` from the Dart side
on a Nim pointer is undefined. The bindings in `flutter/src/frq/core/` wrap
that in a `try/finally` so no call site has to remember.

`frq_init` must be called once before anything else, and calls `NimMain` to set
up Nim's runtime. The bindings do it on first use.

## The web

A native library does not load in a browser, so the web target cannot call this
through `dart:ffi`. Nim compiles through C, so the route is emscripten to wasm
and a JS binding rather than a second implementation — but that is not built
yet, and until it is, **the web build must keep using the ClojureDart
originals**. This is why the originals stay in `common/` rather than being
deleted as each module lands: they are the web's implementation, not dead code.

## The spike

`just nim-spike` opens a window with no ClojureDart on the path, connects to
irc.freeq.at over TLS, joins `#test` and sends a message. Nim owns the state,
the screens, the socket and the IRC protocol; Dart owns the pixels.

```
src/frq/ui.nim              the widget tree, in the screens' own tag vocabulary
src/frq/state.nim           the record, the reducer, and drain()
src/frq/irc.nim             the socket, on its own thread, behind two channels
src/frq/screens/            connect and chat, as pure functions of the state
src/frq/trace.nim           FRQ_TRACE=1, the same switch the rest of frq uses
```

Three decisions worth knowing before changing any of it:

* **Nothing is shared with the socket thread.** Nim's ORC is thread-local for
  ref types, so sharing the state would mean a lock per field and a heap two
  threads both collect. The reader speaks only in channels, and `drain()` turns
  its output into state on whichever thread Dart called in on.
* **Dart polls; Nim never calls back.** A Dart callback from a foreign thread
  has to be marshalled onto the main isolate — `NativeCallable`, ports, a whole
  mechanism — and at 70µs a render a 100ms timer does the same job for free.
* **A prop holds an event id, not a closure.** That is the one thing hiccup has
  that a C ABI cannot, and substituting it is what makes this an architecture
  rather than a rendering trick.

Cost, measured: a full screen rebuild is 70–105µs, or 0.4–0.6% of a 60fps
frame, for a 1.6KB tree. The caveat is the tree size rather than the number —
the chat screen caps the backlog at fifty rows for exactly this reason, and
nothing has measured what a real one costs.

```bash
just nim-spike        # the window; click Connect
FRQ_TRACE=1 FRQ_AUTOCONNECT=1 just nim-spike   # ...connecting on its own
just nim-spike-test   # 7 widget tests: real taps, real widgets
just nim-live         # connect to a real freeq and say a line
just nim-bench        # what the boundary costs
FRQ_TRACE=1 just nim-live    # ...and every line on the wire
```

Two switches, both for the same reason — a GUI on Wayland cannot be clicked
from a script, so without them the only way to check the window connects is to
sit in front of it. `FRQ_AUTOCONNECT=1` presses Connect on the first render and
`FRQ_NICK` overrides the nickname, because two runs with the same one collide
on the server and the second is refused.

The GUI needs OpenSSL on its loader path, which the `flutter-desktop` shell
provides as `FRQ_OPENSSL_LIB` and the `nim-spike` recipe prepends for the app
alone. Not set as `LD_LIBRARY_PATH` in the shell itself: that shell also runs
Flutter through nixGL, which does its own careful things to the loader path,
and a blanket setting there breaks GL on some machines and not others.

## Status

`frq/ircparse.nim` is ported and tested — 29 cases, `just nim-test` — and the
ABI is exercised from C through `dlopen`, including the allocation contract
under a hundred thousand parse/free cycles. That half is real.

The Dart binding is real too, and is `dart/frq_core` — **plain Dart, not
ClojureDart**. It calls the library over `dart:ffi` and is covered by 20 tests
on the Dart VM, including the UTF-8 round trip and ten thousand calls against
the ownership rules. `just dart-test` runs the pair of them in about a second.

The binding was ClojureDart for one commit and should not have been: the Nim
core exists to have less Clojure in the tree, and `lookupFunction` takes two
type arguments, so it meant fighting generic interop to write more of the
thing being removed. In Dart it is a typedef. See `dart/README.md`.

The spike above is wired up and runs. What is **not** done is replacing
anything: the shipping app is still the ClojureDart one, `common/frq/irc/parse.cljc`
is still what it runs, and the spike is a second entry point beside it
(`lib/main_nim.dart`) rather than a replacement for `frq.main`. That step is its
own piece of work — the Flutter app takes the package as a path dependency
(which means a `pubspec.lock` regeneration and widening the nix build's source
root), the library has to reach each target (`jniLibs` for the APK, beside the
executable for the desktop bundle), and only then can a call site choose Nim
on native and the ClojureDart original on the web.

Modules still in `common/` and not yet here: `rooms`, `msgsig`, `crypto`,
`atproto/core`, `oauth/core`, `store`, `irc/handshake`, `irc/mutate`,
`profile`, `members`, `reactions`, `replies`, `edits`, `clock`.

## Building

```bash
just nim-test     # the Nim test suite
just nim-lib      # libfrqcore.so into build/nim
```

Both want `nix develop .#nim`, and re-enter it themselves if they are not
already inside.
