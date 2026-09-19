# Working in this repo

## The toolchain, and where builds happen

There is no nix in the build. `tools/toolchain.sh` fetches Flutter (which
carries Dart) and Nim as sha256-pinned tarballs into `.toolchain/`, and every
`just` recipe runs inside the environment that script prints. The host brings
a C compiler, OpenSSL, git, curl, unzip and python3 — and GTK with the usual
CMake/Ninja/pkg-config for the Linux target.

It used to carry a JDK, the Clojure CLI, a maven repo and an Android SDK as
well. Those were ClojureDart's and the APK's, and both are gone.

**Prefer Modal for a long build.** A cold Flutter toolchain plus a full
compile is a lot of laptop, and the containers in `.modal/` do it on a real
machine:

```bash
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

`nim/` is the program. It owns the state, the screens, the IRC connection and
the signing; Flutter is a renderer over the widget tree it emits. Read
`nim/README.md` before touching it.

Two rules the ABI has, both of which cost a segfault to rediscover:

* Every string the core returns is the **caller's** to free, with `frq_free`.
  Nim's allocator is not Dart's.
* `frq_init` runs once before anything else.

`dart/frq_core` is the other half of that seam. It is a plain Dart package and
not a Flutter one, deliberately: `flutter/pubspec.yaml` depends on the Flutter
SDK, so anything living there needs a Flutter toolchain to check one assertion
about a string, where this resolves and tests on its own.

The rule that used to be here said new Dart-side code is written in Dart
rather than ClojureDart. There is no ClojureDart left for it to rule against,
but the reasoning it rested on still holds for the next thing: logic goes in
Nim, the platform goes in Dart, and neither is written in a third language
because it is already open.

`just test nim` and `just test dart` need no Flutter, which is most of the
point: the whole boundary is checkable in about a second.

There is no `common/` any more, and that rule went with it. It said a module
stays until there is a wasm build of the core, because a browser has no
dart:ffi — which was true, and the web target is gone rather than the rule
being wrong. Bringing it back means compiling the core to wasm, not restoring
ClojureDart.

## The source trees

```
nim/           the program: state, screens, IRC, signing
dart/frq_core  the FFI binding — plain Dart, not a Flutter package
flutter/lib    the renderer, and the app's entry point
```

`nim/src/frq/ui.nim` builds a widget tree; `frq_core` carries it across the
FFI as JSON; `flutter/lib/nim_renderer.dart` walks it into Flutter widgets.
The renderer knows the tag vocabulary and nothing else — no screens, no state,
no idea what "connect" means. If a feature ever needs a change on both sides,
the boundary is in the wrong place.

There used to be two more trees. `src/` was jolt and libcosmic; `common/` and
`flutter/src/` were ClojureDart, compiled for Android, Linux and the web. Both
are gone, and with the second went the APK and the web target: a browser has
no `dart:ffi`, and the APK wants `libfrqcore.so` cross-compiled for Android's
ABIs. What is left builds one thing, `just build desktop`.

Two modules were never ported and are gone rather than moved: `frq.profile`
(the Bluesky profile behind a nick) and `frq.replies` (asking freeq what a
collapsed msgid was). Neither had a screen in the Nim app to appear on.

