# The ClojureDart half

This is the boundary, drawn before the port rather than after it, so that the
question "can this file go on the phone?" has a filesystem answer. It builds:
see "Building it" below.

## The two trees

```
common/   .cljc   portable. No dart: library, no host call except through frq.io.
flutter/  .cljd   Flutter widgets, dart:io, dart:ffi, and the host's answers.
```

The extension is the boundary and the compiler enforces half of it: ClojureDart
reads `.cljd` and `.cljc` and never `.clj`. `tools/check-common.py` enforces the
rest, on every push — a `dart:` library named under `common/` is a namespace
that compiles for one target and not the others.

Where a shared namespace needs a different answer per target, `.cljd` wins over
`.cljc` in ClojureDart's own resolution, so a file here shadows a shared one
without either side knowing. Reader conditionals work too, with one trap from
ClojureDart's FAQ: the `:clj` feature is always on under cljd, so `:clj` goes
**last** in a conditional, and macro code that wants the Clojure path during
host evaluation asks for `:cljd/clj-host`.

## The seam

`frq.io` is the host's job named once. `frq.io.dart` answers it on Android and
the Linux desktop; `frq.io.web` answers it in a browser. It carries the
filesystem, the environment, the config directory and the clock.

`frq.clock` is the shape the rest follows. It used to open with four guesses at
the reader's zone — `TZ`, the target of `/etc/localtime`, the file itself by
path, then Android's `persist.sys.timezone` — and then convert days to a date
by printing one and taking a `subs` of the result. Both are gone: the guessing
is a libc question and lives behind `local-offset-seconds`, which Dart answers
in one call; the conversion is eleven lines of Hinnant's algorithm, checked
against `java.time.LocalDate` for every day from 1901 to 2052.

Adding a host call means adding it to `common/frq/io.cljc` and to every
implementation. Name it for the result rather than the mechanism — the seam has
`write-private-file!` and not a chmod, because Dart has no chmod.

## The port, as it finished

This tree began as the phone half of a client whose desktop was jolt: glimmer
components painted by libcosmic, with `src/` holding the half that could not
cross. That half is gone now, and what was a migration plan is the whole
program. The namespaces that made the trip:

| namespace          | note                                                  |
|--------------------|-------------------------------------------------------|
| `frq.emoji`        | data; nothing to port                                 |
| `frq.glyphs`       | data                                                  |
| `frq.clock`        | zone-hunting moved behind the seam                    |
| `frq.store`        | `install -m 600` became `write-private-file!`         |
| `frq.irc.parse`    | the parser was always pure                            |
| `frq.irc.handshake`| SASL, driven from shared code                         |
| `frq.msgsig`       | needed a crypto seam beside the io one                |
| `frq.atproto.core` | hand-rolled HTTPS became `dart:io`, which has TLS     |
| `frq.oauth.core`   | the broker flow, as far as it is portable             |
| `frq.rooms`, `frq.cells`, `frq.screens/*` | rewritten against `cljd.flutter` |

What did not come: the terminal frontend (there is no terminal Flutter), the
libcosmic one (it is Wayland, X11 and wgpu, and does not cross to a phone), and
the media plane — `moq/`, `codec/`, `capture/`, `av/`, about 3,800 lines of FFI
against C libraries Android does not have either way. `dart:ffi` does not
conjure V4L2; that half wants Flutter's camera and audio plugins and is its own
project. The Call controls in `frq.screens.chat` are still wired to actions no
target installs, which is the visible edge of that.

## Building it

Three targets out of one tree. The ClojureDart compile is the same command for
all of them — `clojure -M:cljd compile` over `src/` and `../common` — and what
differs is only what Flutter is asked to wrap it in.

```bash
just apk                 # the debug APK
just apk install         # and onto a connected device
just apk run             # and launched
just apk log             # logcat

just flutter-desktop     # the debug Linux bundle
just flutter-desktop run # and the window

just flutter-web         # the web bundle
just flutter-web serve   # and served on :8080
```

### The desktop one

`just flutter-desktop` is this tree under Flutter's Linux target — the same
screens out of `common/frq/screens/` as the APK, with `frq.hiccup` emitting
Flutter widgets. There used to be a second desktop GUI beside it, libcosmic
under jolt, walking the same hiccup through a different renderer; it is gone.

Its toolchain is `devShells.flutter-desktop`, which is the APK shell with the
Android half swapped out: clojure and Flutter are the same two packages at the
same pinned rev, and CMake, Ninja, pkg-config and GTK stand where the JDK and
the SDK do. Kept separate rather than merged into one shell because the halves
are disjoint — a desktop build has no use for a few hundred megabytes of
Android SDK.

Still impure, for one of the two reasons the APK is: pub.dev resolution and
Flutter's engine artifacts are network. What it does *not* need is the
writable-`ANDROID_HOME` dance, since nothing here writes into the store — so
there is no `flutter/.home` on this path.

nixGL off NixOS: Flutter paints through GL and the driver that can do that is
the host's.

`linux/` is the Flutter template's GTK runner, renamed — `frq` rather than
`cljd_flutter`, and `uk.nandi.frq` rather than `com.example.cljd_flutter`, so
the binary, the window title and the GTK application id agree with the APK's
`applicationId`.

Two things the desktop target changed in the Dart, both of them cases where
"the phone" had been assumed rather than asked:

* `frq.io.dart/write-private-file!` was a plain write, on the grounds that
  Android storage is already private to the app. On a Linux desktop it is not:
  the file lands under the XDG data directory with the process umask, and it
  holds a broker token. The desktop branch creates the file, restricts it, then
  writes — and Dart having no chmod is why that is a three-step process rather
  than a mode argument.
* `frq.oauth.dart` handed the capture page `frq://auth` unconditionally, to
  raise the app from behind Chrome. Nothing on a desktop claims that scheme, so
  it is now nil there — which `core/capture-html` already documented as the
  desktop case and already handled.

### The APK

Impure on purpose. Gradle resolves its own dependencies over the network and
installs build-tools and a platform into `ANDROID_HOME` as it goes, so it can
neither run in a sandbox nor write to the store. What nix gives is the
toolchain — clojure, a JDK, Flutter, and an SDK composed by androidenv — and
the recipe copies that SDK to `flutter/.home` for Gradle to finish off. That
copy and everything Gradle leaves behind are gitignored.

All of it is the flake's, which it did not used to be. The toolchain was
`nix shell nixpkgs#clojure nixpkgs#jdk17 nixpkgs#flutter` and the SDK was a
`nix build --impure --expr` around `builtins.getFlake
"github:NixOS/nixpkgs/nixos-unstable"` — two references to an *unlocked*
nixpkgs, so the Flutter that compiled the APK and the nixpkgs under everything
else could drift apart without flake.lock changing a line. They are
`devShells.<system>.flutter` and `packages.<system>.android-sdk` now, at the
pinned rev, and the recipe is `nix develop .#flutter --command` over
`nix build .#android-sdk`.

The SDK needs `allowUnfree` and `android_sdk.accept_license`, which cannot be
set on a `legacyPackages` attribute after the fact — hence `androidPkgsFor` in
the flake, a second `import` of the same locked input rather than a second
nixpkgs. The Flutter toolchain is kept out of the default dev shell: it brings
its own Dart and a JDK's worth of closure, and a desktop build wants none of
it.

Two things the Flutter template wanted that are deliberately not here. There is
no `ndkVersion` in `android/app/build.gradle.kts`: setting it makes Gradle
fetch that exact NDK, and there is no native code to need one — the app is
Dart, and path_provider is platform channels rather than JNI. And `ios/`,
`macos/`, `windows/`, `web/` are deleted; `android/` and `linux/` are the
targets.

It is signed with `~/.android/debug.keystore`, through the template's
`signingConfig = signingConfigs.getByName("debug")` — which release builds also
use, so `flutter build apk --release` is not shippable until a real
`signingConfigs.release` is wired up.

## The screens are not rewritten

`frq.hiccup` is an interpreter, not a port. It walks the hiccup the screens
already produce — `[:vbox {:spacing 6} ...]` over about twenty tags, naming no
toolkit — and emits Flutter widgets, so `common/frq/screens/` is shared across
all three targets rather than forked per target.

This is worth being precise about, because the first read of the port said
otherwise. The screens were data all along; what genuinely had to be written
was the other end — the namespaces that touch the host. Which is what `frq.io`
is for, and where `dart:io` paid for the whole exercise.

What `frq.hiccup` does not do is reconciliation of its own: Flutter rebuilds
from the top and diffs its own element tree, so a cell firing rebuilds the
screen rather than the subtree that read it. Fine at this size.

## Every screen shared, and the root that picks between them

All of them are in `common/frq/screens/` — `connect`, `chats`, `chat`,
`settings` (with Discover and the tab frame) and `app`, which carries the split
view, the three dialogs and the decision about which screen is showing. Each
entry point renders `[screens/app]` and nothing else.

Under them: the cells in `frq.cells`, the derivations in `frq.rooms`, the
chrome metrics in `frq.metrics`, and everything a screen cannot do itself
behind `frq.actions` — which each target fills in for itself, the way it fills
in `frq.io`.

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

## What is still open

The port is finished in the sense that matters — there is no other tree left to
move from. What remains is work the port never covered:

1. **The OAuth capture on Android.** `common/frq/oauth/core.cljc` has the URL,
   the handoff payload and the session refresh. What has no Android answer is
   the capture itself: the flow was written for a client that binds a loopback
   socket and serves a page the browser redirects to, and an Android app cannot
   listen on localhost for a browser it does not own. That wants an app link or
   a custom scheme, an intent filter, and a redirect URI the broker will accept
   — a decision about freeq's broker, not a porting problem. The web build has
   its own answer in `frq.oauth.web`, and `just web-local` is why it only
   completes on localhost.
2. **Calls.** The signaling is IRC and is still in the screens; the media plane
   it drove was `libjoltmoq` — Opus, H.264, V4L2, ALSA, MoQ over QUIC — under
   the retired jolt half, and none of it crosses. The Call controls are wired
   to actions no target installs, so they are dead buttons today. Flutter's
   camera and audio plugins are the way back in, and that is its own project:
   either remove the controls or build behind them.

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
