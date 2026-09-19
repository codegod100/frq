#!/usr/bin/env bash
# The cosmic desktop build: stage a runtime, its objects and the source next
# to each other, and write a launcher that starts them.
#
# There is no compilation here of anything written in Jolt — jolt reads
# deps.edn and the source at startup, which is what `nix build .#frq` was also
# doing behind a wrapper script. What that flake output added was a closure:
# a Mesa, a nixGL to put the host's driver in front of it, and a store path
# per dependency. `.#appimage` then squashed the lot into one file so a
# machine without nix could run it.
#
# This builds the same program without any of that. The pieces arrive pinned
# from `tools/desktop-toolchain.sh`, the one thing that IS compiled is a
# single .c file, and what comes out is a directory that runs from wherever
# it is unpacked.
#
#   tools/build-desktop.sh                 build build/desktop
#   tools/build-desktop.sh tar             ...and tar it up beside itself
#   tools/build-desktop.sh run             ...and start it
#
# The container in `.modal/frq/` runs this same file, the way
# `.modal/flutter-web/` runs tools/build-web.sh.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
action="${1:-build}"

case "$action" in build|tar|run) ;; *)
    echo "usage: build-desktop.sh [build|tar|run]" >&2; exit 1 ;;
esac

eval "$("$root/tools/desktop-toolchain.sh" env)"

out="${FRQ_DESKTOP_OUT:-$root/build/desktop}"
rm -rf "$out"
mkdir -p "$out/bin" "$out/lib" "$out/src"

# The runtime.
install -m 0755 "$FRQ_DESKTOP_TOOLCHAIN/jolt/jolt" "$out/bin/jolt"

# Every object in one directory, because JOLT_NATIVE_LIB is one directory:
# jolt resolves each `:jolt/native` name against it. They arrive from two
# places — the portable tarball and the moq-ffi release — which is exactly
# what `nativeAll` was a symlinkJoin for.
cp -a "$FRQ_DESKTOP_TOOLCHAIN/jolt-native/lib/." "$out/lib/"
install -m 0755 "$FRQ_DESKTOP_TOOLCHAIN/moq-ffi/lib/libmoq_ffi.so" "$out/lib/"

# The calling-convention adapter, compiled here because it is one translation
# unit and because openh264's C API cannot be called from Jolt directly:
# `ISVCEncoder` is a `const ISVCEncoderVtbl*`, so `c/frq_h264.c` walks the
# vtable and exports five plain symbols. See src/frq/codec/h264.clj.
#
# This is the one place the build machine's own libraries get in, and the
# reason it is acceptable is the reason the portable tarball works at all:
# openh264, opus and alsa-lib are plain C libraries against glibc, and the
# copy below takes the .so the link actually resolved rather than trusting the
# runner to have the same one.
echo "desktop: compiling the h264 adapter" >&2
cc -O2 -fPIC -shared "$root/c/frq_h264.c" -o "$out/lib/libfrqh264.so" \
    $(pkg-config --cflags --libs openh264)

# openh264 itself, opus, and ALSA's client library, beside it. `ldd` on what
# was just linked names the file the loader chose, which is the one to take —
# a guess at a soname is a guess at the distro.
for soname in libopenh264 libopus libasound; do
    lib=$(ldd "$out/lib/libfrqh264.so" 2>/dev/null | awk -v n="$soname" '$1 ~ "^"n"\\." {print $3; exit}')
    # opus and alsa are opened by jolt rather than NEEDED by the adapter, so
    # they are not in that ldd and have to be looked up.
    [ -n "${lib:-}" ] || lib=$(ldconfig -p | awk -v n="$soname" '$1 ~ "^"n"\\.so" {print $NF; exit}')
    if [ -z "${lib:-}" ]; then
        echo "desktop: no $soname on this machine — the AV plane will not load" >&2
        continue
    fi
    install -m 0755 -T "$lib" "$out/lib/$(basename "$lib")"
done

# $ORIGIN for everything staged here, for the reason jolt-native's
# libsPortable sets it: the consumer decides where this unpacks and only the
# loader knows where that turned out to be. The objects out of the portable
# tarball already have it; the ones added above do not.
if command -v patchelf >/dev/null 2>&1; then
    for f in "$out/lib"/*.so*; do patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true; done
else
    echo "desktop: no patchelf; the launcher's LD_LIBRARY_PATH covers this" >&2
fi

# The project as jolt sees it: source, deps.edn, nothing else — the same three
# things `frqSource` copied in the flake.
cp -a "$root/common" "$root/src" "$root/deps.edn" "$out/src/"

# The two Jolt libraries the launcher names in -Sdeps. Copied in rather than
# referenced out of the toolchain, so the bundle is self-contained: a tarball
# that needs a directory from the machine that made it is not a bundle.
cp -a "$FRQ_GLIMMER" "$out/glimmer"
cp -a "$FRQ_GLIMMER_COSMIC" "$out/glimmer-cosmic"
rm -rf "$out/glimmer/.git" "$out/glimmer-cosmic/.git"

# The launcher. `frqScript` from the flake, with the store paths replaced by
# $ORIGIN-relative ones and the nixGL branch deleted — off NixOS that existed
# to put the host's GL driver ahead of the closure's Mesa, and there is no
# Mesa in here to get ahead of. The driver is simply the host's.
cat > "$out/bin/frq" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

export JOLT_NATIVE_LIB="$here/lib"
export LD_LIBRARY_PATH="$here/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ALSA finds its plugins by directory rather than by soname, and `default`
# resolves to nothing without the PipeWire one. Unlike the flake, which named
# a store path, this defers to the host: every machine frq targets runs
# PipeWire and ships that plugin in the usual place.
for d in /usr/lib/x86_64-linux-gnu/alsa-lib /usr/lib/alsa-lib /usr/lib64/alsa-lib; do
    [ -d "$d" ] && export ALSA_PLUGIN_DIR="$d" && break
done

# jolt resolves deps.edn from the working directory.
cd "$here/src"

exec "$here/bin/jolt" \
    -Sdeps "{:deps {jolt-lang/glimmer {:local/root \"$here/glimmer\"}
                    nandi/glimmer-cosmic {:local/root \"$here/glimmer-cosmic\"}}}" \
    -m frq.cosmic "$@"
LAUNCH
chmod +x "$out/bin/frq"

echo "desktop: built $out" >&2
du -sh "$out" >&2

case "$action" in
    tar)
        tarball="${FRQ_DESKTOP_TAR:-$root/build/frq-desktop-x86_64-linux.tar.gz}"
        mkdir -p "$(dirname "$tarball")"
        # Rooted at a directory of its own, because a tarball that unpacks
        # `bin/` and `lib/` into the current directory is a tarball someone
        # will one day unpack into their home.
        tar czf "$tarball" -C "$(dirname "$out")" "$(basename "$out")"
        echo "desktop: $tarball" >&2
        ls -la "$tarball" >&2
        ;;
    run)
        exec "$out/bin/frq"
        ;;
esac
