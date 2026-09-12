# Working in this repo

## Nix

You are already running inside the Arch distrobox, where `nix` lives, so run
nix commands directly — do not wrap them in `distrobox enter`:

```bash
nix build .#frq
```

A remote builder (`eu.nixbuild.net`) is already configured here. Large builds
want `--store ssh-ng://eu.nixbuild.net --eval-store auto` rather than a
`builders` entry, so the whole graph stays there and only .drv files go up —
libjoltcosmic's dependency tree is the one that makes this worth remembering.

One thing this container is *not* representative of: `/etc/localtime` is a
regular file here rather than a symlink, so anything that reads the zone out
of its path sees nothing. That is a real deployment shape, not an artefact —
frq.clock handles it.

## The three source trees

```
common/  .cljc  jolt AND ClojureDart
src/     .clj   jolt only
flutter/ .cljd  ClojureDart only
```

The extension is the boundary, not a convention: ClojureDart reads `.cljd` and
`.cljc` and never `.clj`, jolt reads all three. So the rule for anything under
`common/` is that it may not require `jolt.*`, `glimmer*` or a `dart:` library
— if it needs the host, it asks `frq.io`, and the backend that installed itself
answers. `frq.io.jolt` is required for its side effect by `frq.app`;
`frq.io.dart` is installed by `flutter/src/frq/main.cljd`, which has to await
the storage directory first.

Adding a host call means adding it to the seam in `common/frq/io.cljc` and to
both implementations. Name it for the result rather than the mechanism — the
seam has `write-private-file!` and not a chmod, because Dart has no chmod.

`flutter/` builds two things, from one `clojure -M:cljd compile`:

`just apk`, out of the flake's own `.#flutter` shell (clojure, jdk17, flutter)
and its `.#android-sdk` package. Impure on purpose: Gradle fetches its own
dependencies and writes into `ANDROID_HOME`, so the recipe copies the store SDK
to `flutter/.home` and lets it finish there. It is the only APK there is — the
jolt APK, `nix/android.nix`, `android/` and the `.#apk` outputs are gone,
because every backend that APK could paint with is retired.

`just flutter-desktop`, out of `.#flutter-desktop` (the same clojure and
flutter, with cmake, ninja, pkg-config and gtk3 where the JDK and the SDK are).
Impure for the network half of the same reasons and no writable-SDK dance, since
nothing writes into the store. nixGL off NixOS, like `just run`.

So there are two desktop GUIs and they are both first-class: `just run` is
libcosmic under jolt, `just flutter-desktop` is Flutter's Linux target over
`frq.hiccup`. Same screens out of `common/frq/screens/`, two renderers. jvui and
Vidya were experiments and are gone; libcosmic is a desktop window and does not
cross to a phone, which is what the Flutter half is for.

The consequence for `common/` is that "the phone" is no longer a synonym for
"the ClojureDart side" — two targets compile it. An implementation that branches
on the platform has to ask (`Platform.isAndroid`) rather than assume; see
`frq.io.dart/write-private-file!`, where assuming cost a token its file mode.
See flutter/README.md.
