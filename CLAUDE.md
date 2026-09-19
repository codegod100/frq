# Working in this repo

## Nix

**STOP BUILDING LOCALLY. Build on Modal.** This machine is for editing and for
evaluating — `nix flake check`, `nix eval`, `nix build --dry-run`, `nix repl`
— and not for realising a derivation. A local `nix build .#frq` gets killed for
memory long before it finishes, and the minutes spent finding that out are
minutes not spent on the change. So:

```bash
modal run .modal/frq/container.py   # the desktop bundle, on Modal
```

The container is `.modal/`, not a fourth source tree: it is CI config that
happens to live here, the way `.github/` would be.

`--dry-run` locally to see what *would* be built, then hand the build to Modal.
The one exception is a derivation you already know is trivial and already
substitutable; if you are unsure, it is not the exception.

`modal app logs` is no substitute for watching that command: it resolves
deployed apps by name, not the ephemeral one a `modal run` creates, and carries
nothing until the Sandbox starts — the image build streams to the client and
nowhere else.

You are already running inside the Arch distrobox, where `nix` lives, so run
the evaluating commands directly — do not wrap them in `distrobox enter`.

The container runs as a Modal **Sandbox on a real VM**, which is what makes
`nix build` work out there at all: the ptyshim that used to stand in for a
working pty under gVisor is deprecated, and nothing here should reintroduce it.
Substitution comes from the `nix-cache` Modal Volume plus cache.nixos.org and
nix-cache.wasix.org — libjoltcosmic's dependency tree is the one that makes
that cache worth having.

A remote builder (`eu.nixbuild.net`) is also configured here, for the case
where you want the graph built somewhere other than Modal: `--store
ssh-ng://eu.nixbuild.net --eval-store auto` rather than a `builders` entry, so
the whole graph stays there and only .drv files go up.

One thing this container is *not* representative of: `/etc/localtime` is a
regular file here rather than a symlink, so anything that reads the zone out
of its path sees nothing. That is a real deployment shape, not an artefact —
frq.clock handles it.

## Never pipe a long task through `tail`

`tail` and `head` do not emit anything until their input ends, so a build, a
test run or a deploy piped through one shows nothing at all until it is over —
and if it is killed or times out first, its output is lost with it. That is the
opposite of what you want from the commands that take longest.

Let them write to the terminal, or `tee` them if you want a copy to grep
afterwards:

```bash
modal run .modal/frq/container.py 2>&1 | tee /tmp/frq-build.log
```

Trim afterwards, on the file, where the whole run is still there to re-read.
The same goes for `grep` and `awk` in a live pipeline: they buffer when their
output is not a terminal, so pass `--line-buffered` / `fflush()` or watch the
file instead.

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
nothing writes into the store. nixGL off NixOS, like `just cosmic run`.

So there are two desktop GUIs and they are both first-class: `just cosmic
run` is libcosmic under jolt, `just flutter-desktop` is Flutter's Linux target
over
`frq.hiccup`. Same screens out of `common/frq/screens/`, two renderers. jvui and
Vidya were experiments and are gone; libcosmic is a desktop window and does not
cross to a phone, which is what the Flutter half is for.

The consequence for `common/` is that "the phone" is no longer a synonym for
"the ClojureDart side" — two targets compile it. An implementation that branches
on the platform has to ask (`Platform.isAndroid`) rather than assume; see
`frq.io.dart/write-private-file!`, where assuming cost a token its file mode.
See flutter/README.md.
