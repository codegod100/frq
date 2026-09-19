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
tests/                  one per module, run by `just test nim`
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

## What is wired up

`just run app` is the real client with the Nim core as its transport. Every
screen, cell and action is the one that was already there; `frq.main-nim` is
`frq.main` with one line changed.

```
src/frq/conn.nim      the socket, the TLS, the line framing — on its own thread
src/frq/ircparse.nim  the IRC wire format
src/frq/trace.nim     FRQ_TRACE=1, the same switch the rest of frq uses
```

The seam is `frq.net`, which already existed with two implementations;
`flutter/src/frq/net/nim.cljd` is a third beside `frq.net.dart` and
`frq.net.web`. Nim owns the socket and nothing above it — the line goes to the
existing `frq.irc.parse`, so `on-msg` receives the same map from the same
parser and nothing upstairs can tell which transport it is on.

Two things to know before changing `conn.nim`:

* **Nothing is shared with the socket thread.** Nim's ORC is thread-local for
  ref types, so sharing state would mean a lock per field and a heap two
  threads both collect. It speaks only in channels.
* **Writes drain before reads.** IRC has the client speak first, and reading
  first deadlocked completely: CAP/NICK/USER sat queued while the loop waited
  for a server that had nothing to say until we registered.

There was an experiment where Nim owned the state and the screens too. It is
gone. It meant a 43-line chat screen standing in for 1,518 — no reactions, no
replies, no images — and the path forward from it was rewriting every screen
in Nim and losing all of that. It is at 1d62d1a if it is ever wanted.

```bash
just run app         # the real client, Nim transport
just test nim        # the Nim suite
just test dart       # the Dart side of the boundary
just build lib       # libfrqcore.so into build/nim

FRQ_TRACE=1 just run app    # every line in and out, both languages
```

The GUI needs OpenSSL on its loader path: Nim resolves the entry points
through dynlib at run time, and without the library there `newContext` dies in
a SIGSEGV that says nothing about SSL. The recipe prepends `FRQ_OPENSSL_LIB`
for the app alone, so a host whose libssl is somewhere unusual has one variable
to set rather than an `LD_LIBRARY_PATH` to inherit.

## Status

`frq/ircparse.nim` is ported and tested — 29 cases, `just test nim` — and the
ABI is exercised from C through `dlopen`, including the allocation contract
under a hundred thousand parse/free cycles. That half is real.

The Dart binding is real too, and is `dart/frq_core` — **plain Dart, not
ClojureDart**. It calls the library over `dart:ffi` and is covered by 20 tests
on the Dart VM, including the UTF-8 round trip and ten thousand calls against
the ownership rules. `just test dart` runs the pair of them in about a second.

The binding was ClojureDart for one commit and should not have been: the Nim
core exists to have less Clojure in the tree, and `lookupFunction` takes two
type arguments, so it meant fighting generic interop to write more of the
thing being removed. In Dart it is a typedef. See `dart/README.md`.

The transport is wired up and runs. What is **not** done is replacing
anything else: `frq.main` is untouched and still installs `frq.net.dart`, so
the shipping app is unchanged and `frq.main-nim` is a second entry point
beside it. `common/frq/irc/parse.cljc` is still what does the parsing on every
target, including this one. That step is its
own piece of work — the Flutter app takes the package as a path dependency
(which means a `pubspec.lock` regeneration), the library has to reach each target (`jniLibs` for the APK, beside the
executable for the desktop bundle), and only then can a call site choose Nim
on native and the ClojureDart original on the web.

Modules still in `common/` and not yet here: `rooms`, `msgsig`, `crypto`,
`atproto/core`, `oauth/core`, `store`, `irc/handshake`, `irc/mutate`,
`profile`, `members`, `reactions`, `replies`, `edits`, `clock`.

## Building

```bash
just test nim     # the Nim test suite
just build lib    # libfrqcore.so into build/nim
```

Both run out of `.toolchain/`, which `tools/toolchain.sh` fills on first
use. What they want from the host is a C compiler -- `nim c` shells out to one
-- and OpenSSL.
