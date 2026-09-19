# `frq`

    modal run .modal/frq/container.py
    just modal frq

Defined by `container.toml`; see `../spec.md` for the keys.
Built on `debian:13-slim`.

No nix, and — as with `flutter-web` — that is the point of this
container rather than an incidental fact about it. What comes out is
`build/frq-desktop-x86_64-linux.tar.gz`: a directory with a jolt
binary, the native objects, this tree's source, glimmer and
glimmer-cosmic, and a launcher. Unpack it anywhere and run
`bin/frq`.

## What replaced the AppImage

It used to be `nix build .#appimage` on an Arch-with-nix image,
against a `nix-cache` volume, with an hour's timeout sized for
libjoltcosmic's dependency tree and a substituter test to decide
whether writing the cache back was worth more than the build it
avoided.

None of that was nix doing a bad job. It was nix building from
source what is now published in a form a machine without nix can
use:

| piece | where it comes from now |
| --- | --- |
| `jolt` | a release binary, chez linked in statically — stock `/lib64` interpreter, NEEDED `libc` and `libm` |
| `libjoltcosmic`, `libjolttui`, `libvidya`, `libjoltmoq` | jolt-native's `x86_64-linux-portable.tar.gz` — RUNPATH `$ORIGIN`, NEEDED closure alongside |
| `libmoq_ffi` | an upstream release object |
| `glimmer`, `glimmer-cosmic` | source, cloned at a pinned rev |
| `libfrqh264.so` | one `.c` file, compiled here |

What was left after that was a Mesa, and a nixGL to put the host's
driver in front of it. The AppImage existed to carry the closure
that Mesa was part of. Not carrying a Mesa means not needing a
nixGL, which means not needing the bundle — the GL driver is the
host's, the way it is for every other program on the machine.

`tools/desktop-toolchain.sh` holds the pins and
`tools/build-desktop.sh` does the assembly; `just desktop` runs the
same script on a laptop. The toolchain lands on the `devshell`
volume and a second run finds it there.

## The pin that has to be filled in

`JOLT_NATIVE_SHA` in `tools/desktop-toolchain.sh` is a placeholder
until jolt-native's pipeline has published a portable tarball for
the revision named beside it. The script refuses to fetch until it
is real rather than falling back to an unpinned download — the
package registry serves the newest upload under a given name, which
is exactly the moving target a pin is for. It prints the two
commands that fix it.

## What is not in the bundle

The GL driver and glibc, on purpose — both are the host's, and a
newer loader can load an older program's libraries rather than the
reverse.

The ALSA PipeWire plugin, also the host's. The flake named a store
path for it; the launcher looks in the three places a distro puts
it. Without it `default` resolves only to raw hardware devices,
which PipeWire is already holding.

`libjolttui` rides along in the tarball because it is in the
portable one, but nothing in this bundle starts it — `.#tui` is
still a nix output and the terminal backend needs no bundle to be
useful.

## Runs as a Sandbox

On a real VM (kernel 6.x, not gVisor), the command being the
sandbox's own process, so it dies when the command exits. It builds
only: there is no GL and no display here, and nothing tries to open
the window.
