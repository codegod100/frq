# Working in this repo

## Nix

**STOP BUILDING LOCALLY. Build on Modal.** This machine is for editing and for
evaluating — `nix flake check`, `nix eval`, `nix build --dry-run`, `nix repl`
— and not for realising a derivation. A local build of the whole graph gets
killed for memory long before it finishes, and the minutes spent finding that
out are minutes not spent on the change. So:

```bash
modal run .modal/flutter-web/container.py   # the web bundle, on Modal
modal run .modal/flutter-dev/container.py   # the incremental Flutter loop
```

The containers in `.modal/` are not a third source tree: they are CI config
that happens to live here, the way `.github/` would be.

`--dry-run` locally to see what *would* be built, then hand the build to Modal.
The one exception is a derivation you already know is trivial and already
substitutable; if you are unsure, it is not the exception.

`modal app logs` is no substitute for watching that command: it resolves
deployed apps by name, not the ephemeral one a `modal run` creates, and carries
nothing until the Sandbox starts — the image build streams to the client and
nowhere else.

You are already running inside the Arch distrobox, where `nix` lives, so run
the evaluating commands directly — do not wrap them in `distrobox enter`.

The containers run as Modal **Sandboxes on a real VM**, which is what makes a
build work out there at all: the ptyshim that used to stand in for a working
pty under gVisor is deprecated, and nothing here should reintroduce it. Neither
container carries nix: `tools/toolchain.sh` fetches Flutter, a JDK and the
Clojure CLI by sha256 onto the `devshell` Volume, and the build runs out of
those.

A remote builder (`eu.nixbuild.net`) is also configured here, for the case
where you want a derivation built somewhere other than Modal: `--store
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
modal run .modal/flutter-web/container.py 2>&1 | tee /tmp/frq-build.log
```

Trim afterwards, on the file, where the whole run is still there to re-read.
The same goes for `grep` and `awk` in a live pipeline: they buffer when their
output is not a terminal, so pass `--line-buffered` / `fflush()` or watch the
file instead.

## The Nim core

`nim/` is the portable logic, moving out of `common/` one module at a time as
a native library the Dart side calls through FFI. Read `nim/README.md` before
touching it — in particular the status section, which says what is actually
wired up (the Nim half and its ABI) and what is not (the Dart binding).

Two rules the ABI has, both of which cost a segfault to rediscover:

* Every string the core returns is the **caller's** to free, with `frq_free`.
  Nim's allocator is not Dart's.
* `frq_init` runs once before anything else.

`just nim-test` needs no Flutter and no Dart, which is most of the point.

A module is not deleted from `common/` when its Nim version lands: the web
target cannot load a native library, so the ClojureDart original is the web's
implementation until there is a wasm build. Deleting one would take the web
build with it.

## The two source trees

```
common/  .cljc  portable — every target compiles it
flutter/ .cljd  the Flutter half, and the host implementations
```

The extension is the boundary, not a convention: ClojureDart reads `.cljd` and
`.cljc` and never `.clj`. The rule for anything under `common/` is that it may
not require a `dart:` library — if it needs the host, it asks `frq.io`, and the
implementation that installed itself answers. `frq.io.dart` is installed by
`flutter/src/frq/main.cljd`, which has to await the storage directory first;
`frq.io.web` by `main_web.cljd`.

Adding a host call means adding it to the seam in `common/frq/io.cljc` and to
every implementation. Name it for the result rather than the mechanism — the
seam has `write-private-file!` and not a chmod, because Dart has no chmod.

There used to be a third tree, `src/`, and a second runtime under it: jolt,
glimmer, and a libcosmic desktop window painting the same screens. It is gone,
along with `just cosmic`, `just tui`, the AV/MoQ media plane and the native
objects they loaded. Flutter is the only frontend now, and `common/` is
compiled by one compiler rather than two — which is why the `#?(:jolt ...)`
reader conditionals that used to be scattered through it are not there any
more. `tools/check-common.py` still guards the seam, and CI still runs it on
every push.

`flutter/` builds three things, from one `clojure -M:cljd compile`:

`just apk`, out of the flake's own `.#flutter` shell (clojure, jdk17, flutter)
and its `.#android-sdk` package. Impure on purpose: Gradle fetches its own
dependencies and writes into `ANDROID_HOME`, so the recipe copies the store SDK
to `flutter/.home` and lets it finish there.

`just flutter-desktop`, out of `.#flutter-desktop` (the same clojure and
flutter, with cmake, ninja, pkg-config and gtk3 where the JDK and the SDK are).
Impure for the network half of the same reasons and no writable-SDK dance,
since nothing writes into the store. nixGL off NixOS.

`just flutter-web`, out of no nix shell at all — `tools/toolchain.sh` fetches
the three pinned tarballs it needs, which is what lets `.modal/flutter-web/`
run the same script on a plain Debian image.

The consequence for `common/` is that "the phone" is not a synonym for "the
ClojureDart side": three targets compile it. An implementation that branches on
the platform has to ask (`Platform.isAndroid`) rather than assume; see
`frq.io.dart/write-private-file!`, where assuming cost a token its file mode.
See flutter/README.md.
