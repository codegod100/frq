# Working in this repo

## The toolchain, and where builds happen

There is no nix in the build any more. `tools/toolchain.sh` fetches Flutter
(which carries Dart), a JDK, the Clojure CLI and Nim as sha256-pinned tarballs
into `.toolchain/`, and every `just` recipe runs inside the environment that
script prints. `just tools android` adds Google's command-line tools, which is
what `just build apk` needs before Gradle can have sdkmanager finish the SDK
off. The host still brings a C compiler, OpenSSL, git, curl, unzip and
python3 — and GTK with the usual CMake/Ninja/pkg-config for the Linux targets.

**Prefer Modal for a long build.** A cold Flutter toolchain plus a full
compile is a lot of laptop, and the containers in `.modal/` do it on a real
machine:

```bash
just modal web    # the web bundle, on Modal
just modal dev    # the incremental Flutter loop
```

The containers in `.modal/` are not a third source tree: they are CI config
that happens to live here, the way `.github/` would be. They run the very same
`tools/toolchain.sh`, which is why a plain Debian image is enough.

`modal app logs` is no substitute for watching that command: it resolves
deployed apps by name, not the ephemeral one a `modal run` creates, and carries
nothing until the Sandbox starts — the image build streams to the client and
nowhere else.

The containers run as Modal **Sandboxes on a real VM** rather than under
gVisor: a real kernel, a working pty, and memory that is exactly what
`[resources] memory` asks for.

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
modal run .modal/web/container.py 2>&1 | tee /tmp/frq-build.log
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

`dart/frq_core` is the other half of that seam, and is **plain Dart**. New
code on the Dart side of the boundary is written in Dart rather than
ClojureDart — the core exists to have less Clojure in the tree, and adding
more of it to call the thing replacing it is the wrong direction. ClojureDart
shrinks from both ends.

`just test nim` and `just test dart` need no Flutter, which is most of the
point: the whole boundary is checkable in about a second.

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

`just build apk`. Impure on purpose: Gradle resolves its own dependencies over
the network and has sdkmanager install a platform and build-tools into
`ANDROID_HOME` as it goes, which is why that SDK lives in `.toolchain/` and is
ours to write to.

`just build desktop`, Flutter's Linux target — CMake, Ninja, pkg-config and
GTK from the host where the APK wants a JDK and an SDK. Impure for the network
half of the same reasons.

`just build web`, which needs least of all: a Dart, a JVM and a browser, and
the browser is not ours. That is what lets `.modal/web/` run the same
`tools/build-web.sh` on a plain Debian image.

The consequence for `common/` is that "the phone" is not a synonym for "the
ClojureDart side": three targets compile it. An implementation that branches on
the platform has to ask (`Platform.isAndroid`) rather than assume; see
`frq.io.dart/write-private-file!`, where assuming cost a token its file mode.
See flutter/README.md.
