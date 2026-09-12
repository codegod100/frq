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

`frq.main` paints `frq.app`'s own connect screen, out of
`common/frq/screens/connect.cljc` — the same file the desktop renders. What it
reads is `frq.cells` and what it calls is `frq.actions`, and each platform
fills those in: `frq.state`'s reducers on the desktop, dart:io here.

## Three screens shared, all drawn on both

`frq.screens.connect`, `frq.screens.chats` and `frq.screens.chat` are in
`common/`, with the cells under them in `frq.cells`, the derivations in
`frq.rooms`, the backend metrics in `frq.metrics` and everything a screen
cannot do itself behind `frq.actions`. `frq.app` is 621 lines and was 1,744.

What `Length::Fill` means took four goes to get right, and the rule it ended
at is worth stating once: a child that fills is Flutter's `Expanded`, the
question is recursive — a plain `:vbox` holding a `:scroll` fills too — a Row
holding a filling column must `stretch` and be given a height, and a pane that
fills a column takes the row's width as well, or it is as wide as its longest
line. Prose in a row is `Flexible` rather than `Expanded`, because Expanded
hands out equal shares and a button label then wraps down the middle of a
word.

And `:width-request 0` means no request. Every number is truthy in Clojure, so
taking it at face value gave the message list a `SizedBox` of zero width and
an empty screen.

## The older note, kept because the lesson is general

`frq.screens.connect` and `frq.screens.chats` are in `common/` now, with the
cells under them in `frq.cells`, the derivations in `frq.rooms`, the backend
metrics in `frq.metrics` and the things a screen cannot do itself behind
`frq.actions`. `frq.app` requires both and the desktop draws them — verified in
the TUI, including the conversation list with its rooms and previews.

The phone draws both.

`Length::Fill` is the whole of what the renderer was missing, in two
directions. `:fill-height` down a column and a width-less `:entry` across a
row are the same instruction — *take what is left* — and that is Flutter's
`Expanded`, not a bigger `mainAxisSize`. A band that says only `max` is handed
loose constraints by its parent, asks for infinity, and takes the screen with
it.

So `flexed` wraps whichever children fill, with `fills-column?` for a column
and `fills-row?` for a row, and a Row holding one is `max` so it has width to
divide. A `:page` scrolls itself and a `:vbox :fill-height` takes the bounded
height the Scaffold gives it — which is why nothing wraps the screen any more:
a scroll view around the tree is exactly what takes that bound away.

What made this expensive was looking for it as an exception. A layout error
happens after the build: no `try` sees it, `(catch Object ...)` sees it, the
red error box does not appear, and the log stays empty. `FlutterError.onError`
is where they go, and installing that handler in `frq.main` should have been
the first move rather than the tenth.

## The order to do the rest in

1. ~~**`frq.irc`**~~ — started. The parser is `common/frq/irc/parse.cljc` now,
   shared, with `frq.irc` re-exporting it so the twenty-three `irc/tag-value`
   and `irc/nick-of` call sites in `frq.state` and `frq.av` did not move. The
   transport is `frq.net.dart`: `SecureSocket`, a `Stream`, no thread and no
   outbox. **TLS reaches irc.freeq.at:6697 from the phone** — registration and
   MOTD, which is the thing the jolt APK could never do. What is left of this
   one is the protocol half: CAP, SASL and the idle-ping logic still live in
   `src/frq/irc.clj` and want `frq.msgsig` and `frq.atproto` under them first.
2. ~~**`frq.atproto`**~~ — done. `common/frq/atproto/core.cljc` is the JSON,
   the base64url, the SASL payloads, and a `-req`/`-parse` pair per step of the
   flow; `frq.atproto` and `frq.atproto.dart` supply the middle. **handle → DID
   → PDS resolves on the phone**, over `HttpClient`.

   **`frq.oauth`** — half done. `common/frq/oauth/core.cljc` has the URL, the
   handoff payload and the session refresh. What has no Android answer yet is
   the capture: the desktop binds a loopback socket and serves a page the
   browser redirects to, and an Android app cannot listen on localhost for a
   browser it does not own. That wants an app link or a custom scheme, an
   intent filter, and a redirect URI the broker will accept — a decision about
   freeq's broker, not a porting problem.
3. **`frq.msgsig`** (268), **`frq.wire`** (81) — need a crypto seam beside the
   io one.
4. **`frq.avatars`**, **`frq.media`**, **`frq.profile`**, **`frq.platform`** —
   small, and mostly fetch-and-cache.
5. **`frq.state`** moves to `common/` as `.cljc`, with `atom` resolved per
   platform by reader conditional.
6. **`frq.app`** follows it, and the tags it uses that `frq.hiccup` does not
   cover yet paint as an orange `?tag` until they do.

## What a missing tag property looks like

Worth writing down, because it cost an evening. `frq.hiccup` ignored
`:width-request`, and the connect screen puts two entries side by side in an
`:hbox` with one. A TextField takes its width from its parent and a Row offers
unbounded width, so that is a hard layout error — and a layout error happens
after the build, so it is not an exception anything can catch, paints nothing
at all rather than Flutter's red box, and takes every sibling in the same
`children` vector down with it. The screen was blank and the log was empty.

The way through was a harness that renders each candidate in turn with a
labelled marker between them, so the last label standing says where it died.
Not guesswork: four wrong theories went past before that — `Center` in an
unbounded height, `fn*` as a binding name, qualified symbols in `:watch`, a
`Builder` boundary — each one a three-minute deploy.

It also found that two `:entry` nodes with no `:key` shared one
TextEditingController, so the host field showed the port. glimmer matches
children by position when there is no key; a backend holding a controller per
field needs a name for it.
