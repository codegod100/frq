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

## Status

`frq/ircparse.nim` is ported and tested — 29 cases, `just nim-test` — and the
ABI is exercised from C through `dlopen`, including the allocation contract
under a hundred thousand parse/free cycles. That half is real.

The Dart binding (`flutter/src/frq/core/ffi.cljd`) is **not**: it is written
but nothing requires it, so no build has compiled it. Nothing calls the core
yet, and `common/frq/irc/parse.cljc` is still what every target actually runs.

The next step is that binding, and it is the one with the unknown in it:
`.lookupFunction` takes native and Dart type arguments, and how ClojureDart
spells a generic interop call is the thing to establish before porting a
second module. After it: the library has to reach the targets — `jniLibs` for
the APK, beside the executable for the desktop bundle — and then
`frq.core.irc` can choose between the Nim implementation and the ClojureDart
one per target, which is also how the web keeps working.

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
