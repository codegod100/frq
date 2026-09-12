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

`flutter/` does not build; there is no cljd toolchain or Flutter SDK in the
flake. See flutter/README.md. It is the only APK there is — the jolt APK,
`nix/android.nix`, `android/` and the `.#apk` outputs are gone, because every
backend that APK could paint with is retired. jvui and Vidya were experiments;
libcosmic is the desktop window and does not cross to a phone.
