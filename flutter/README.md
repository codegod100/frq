# The ClojureDart half

Nothing here builds yet. This is the boundary, drawn before the port rather
than after it, so that the question "can this file go on the phone?" has a
filesystem answer.

## The three trees

```
common/   .cljc   both compilers. No jolt, no glimmer, no dart.
src/      .clj    jolt: glimmer, jolt.ffi, the cosmic and tui backends.
flutter/  .cljd   ClojureDart: Flutter widgets, dart:io, dart:ffi.
```

The extension is the boundary and the compilers enforce it. ClojureDart reads
`.cljd` and `.cljc` and never `.clj`, so a namespace that reaches for
`jolt.host` cannot accidentally end up in the APK — it is a `.clj` and the Dart
compiler cannot see it. jolt reads all three, which is why `common/` works at
all: one copy of `frq.clock`, compiled twice.

Where both need a namespace but the answer differs, `.cljd` wins over `.cljc`
in ClojureDart's own resolution, so a file here shadows a shared one without
either side knowing. Reader conditionals work too, with one trap from
ClojureDart's FAQ: the `:clj` feature is always on under cljd, so `:clj` goes
**last** in a conditional, and macro code that wants the Clojure path during
host evaluation asks for `:cljd/clj-host`.

## What has crossed

`frq.io` is the seam — the host's job named once, with `frq.io.jolt` answering
it on the desktop and `frq.io.dart` here. It carries the filesystem, the
environment, the config directory and the clock.

Moved to `common/` and running under jolt today:

| namespace     | lines | note                                            |
|---------------|-------|-------------------------------------------------|
| `frq.emoji`   | 1,914 | data; nothing to port                           |
| `frq.glyphs`  |    84 | data                                            |
| `frq.av.dial` |   117 | already touched neither jolt nor glimmer        |
| `frq.clock`   |    93 | zone-hunting moved into the backends            |
| `frq.store`   |   122 | `install -m 600` became `write-private-file!`   |

`frq.clock` is the shape the rest should follow. It used to open with four
guesses at the reader's zone — `TZ`, the target of `/etc/localtime`, the file
itself by path, then Android's `persist.sys.timezone` — and then convert days
to a date by printing one with `jolt.time.local` and taking a `subs` of the
result. Both are gone: the guessing is a libc question and lives in
`frq.io.jolt`, where Dart answers it in one call instead; the conversion is
eleven lines of Hinnant's algorithm, checked against `java.time.LocalDate` for
every day from 1901 to 2052.

## What has not

Roughly 4,000 lines are portable in substance and still `.clj` because the seam
does not reach far enough yet. In the order worth doing them:

1. **`frq.wire`, `frq.msgsig`** — need a crypto seam beside the io one.
2. **`frq.irc`** (433) — the parser is pure; the reader is a blocking thread in
   a `future`, and Dart has no threads. It becomes a `Stream` over
   `SecureSocket`, which is also what makes TLS work on the phone at all.
3. **`frq.atproto`** (209), **`frq.oauth`** (182) — hand-rolled HTTPS over
   `jolt.mvn-http`'s OpenSSL bindings, which is why sign-in is desktop-only
   today. `dart:io` has TLS in the runtime; this is the single biggest thing
   the port buys.
4. **`frq.state`** (1,930) — mostly portable logic, but its ratoms are
   glimmer's. Needs the reactive layer decided first.
5. **`frq.app`** (1,834) — not a port. Flutter brings its own reconciler, so
   the screens are rewritten against `cljd.flutter`.

Not coming: `frq.tui` (no terminal Flutter), `frq.cosmic` (libcosmic is
desktop-only), and the media plane — `moq/`, `codec/`, `capture/`, `av/`, about
3,800 lines of FFI against C libraries that do not exist on Android either way.
`dart:ffi` does not conjure V4L2; that half wants Flutter's camera and audio
plugins and is its own project.

## Building it

```bash
just apk            # the debug APK
just apk install    # and onto a connected device
just apk run        # and launched
just apk log        # logcat
```

Impure on purpose. Gradle resolves its own dependencies over the network and
installs build-tools and a platform into `ANDROID_HOME` as it goes, so it can
neither run in a sandbox nor write to the store. What nix gives is the
toolchain — clojure, a JDK, Flutter, and an SDK composed by androidenv — and
the recipe copies that SDK to `flutter/.home` for Gradle to finish off. That
copy and everything Gradle leaves behind are gitignored.

Two things the Flutter template wanted that are deliberately not here. There is
no `ndkVersion` in `android/app/build.gradle.kts`: setting it makes Gradle
fetch that exact NDK, and there is no native code to need one — the app is
Dart, and path_provider is platform channels rather than JNI. And `ios/`,
`macos/`, `windows/`, `web/` are deleted; `android/` and `linux/` are the
targets.

It is signed with `~/.android/debug.keystore`, through the template's
`signingConfig = signingConfigs.getByName("debug")` — which release builds also
use, so `flutter build apk --release` is not shippable until a real
`signingConfigs.release` is wired up. The jolt APK's key was generated inside
its own nix derivation and never written anywhere, which is why the first
install over it needed an uninstall: Android will not update a package across a
signature change.

## The screens are not rewritten

`frq.hiccup` is a glimmer backend, the same way glimmer-cosmic and glimmer-tui
are. It walks the hiccup `frq.app` already produces and emits Flutter widgets,
so the screens are shared rather than forked.

This is worth being precise about, because the first read of the port said
otherwise. Measured against the source:

* `frq.state` is 1,930 lines and makes **zero** glimmer calls. Its whole
  dependency on glimmer is `:refer [atom]` — it shadows core's `atom` with a
  ratom, and everything after that is `swap!`, `reset!` and `deref`.
* `frq.app` is 1,834 lines and makes **one**: `r/reaction`. The rest is data —
  `[:vbox {:spacing 6} ...]` over about twenty tags, naming no toolkit.

So what a Flutter port needs is an interpreter for that data, not a rewrite of
it. What genuinely has to be ported is the other end: `frq.irc`, `frq.atproto`,
`frq.oauth`, `frq.avatars`, `frq.media`, `frq.profile`, `frq.platform` — the
namespaces that touch the host. Which is what `frq.io` is for, and where
`dart:io` pays for the whole exercise.

What `frq.hiccup` does not do is glimmer's reconciliation: Flutter rebuilds
from the top and diffs its own element tree, so a cell firing rebuilds the
screen rather than the subtree that read it. Fine at this size.

`frq.main` still paints a hand-written tree rather than `frq.app`'s own. Not
because the screens need changing — because requiring them pulls `frq.state`,
which pulls `frq.irc`, which reaches for jolt.host. The tree it paints uses
only tags `frq.app` uses, so it is a test of the backend and nothing more.

## The order to do the rest in

1. ~~**`frq.irc`**~~ — started. The parser is `common/frq/irc/parse.cljc` now,
   shared, with `frq.irc` re-exporting it so the twenty-three `irc/tag-value`
   and `irc/nick-of` call sites in `frq.state` and `frq.av` did not move. The
   transport is `frq.net.dart`: `SecureSocket`, a `Stream`, no thread and no
   outbox. **TLS reaches irc.freeq.at:6697 from the phone** — registration and
   MOTD, which is the thing the jolt APK could never do. What is left of this
   one is the protocol half: CAP, SASL and the idle-ping logic still live in
   `src/frq/irc.clj` and want `frq.msgsig` and `frq.atproto` under them first.
2. **`frq.atproto`** (209), **`frq.oauth`** (182) — hand-rolled HTTPS over
   OpenSSL bindings today, `dart:io` and `package:http` here.
3. **`frq.msgsig`** (268), **`frq.wire`** (81) — need a crypto seam beside the
   io one.
4. **`frq.avatars`**, **`frq.media`**, **`frq.profile`**, **`frq.platform`** —
   small, and mostly fetch-and-cache.
5. **`frq.state`** moves to `common/` as `.cljc`, with `atom` resolved per
   platform by reader conditional.
6. **`frq.app`** follows it, and the tags it uses that `frq.hiccup` does not
   cover yet paint as an orange `?tag` until they do.
