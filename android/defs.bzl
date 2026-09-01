# Where libvidya comes from, which is a question with two answers.
#
# A BUCK file cannot branch — `if` outside a `def` is not this dialect — and
# this is not a `select` either: it does not vary by configuration but by
# whether a checkout is sitting next to this one. So it lives in a macro.
def libvidya(name):
    """The Android libvidya: a sibling checkout's, or the pinned release's.

    Either way the library's bytes are an input to what reads them, which is
    the part that matters — an action that shelled out to build it would have
    nothing to invalidate on and would serve the same stale object forever.
    """
    if native.read_root_config("frq", "libvidya", "pinned") == "checkout":
        # Staged by the `buck` recipe out of the sibling jolt-native, so that
        # anyone working on both repos at once builds what they are editing.
        native.export_file(
            name = name,
            src = "prebuilt/arm64-v8a/libvidya.so",
            mode = "reference",
        )
    else:
        # The release, fetched by digest. This is what makes an APK buildable
        # with no jolt-native checkout and no NDK anywhere on the machine.
        native.genrule(
            name = name,
            out = "libvidya.so",
            cmd = "cp $(location toolchains//dist:libvidya-android)/libvidya.so \"$OUT\"",
        )

def glue(c_name, include_name):
    """jolt_main.c and the ABI's headers, from wherever libvidya came from.

    Targets rather than paths, and that is the point: naming a checkout's file
    by absolute path leaves buck with nothing to notice when it changes, so
    editing the glue rebuilt nothing and the APK kept the old object. It has to
    be an input.
    """
    if native.read_root_config("frq", "libvidya", "pinned") == "checkout":
        # Staged by the `buck` recipe, because a cell cannot reach outside its
        # own root.
        native.export_file(
            name = c_name,
            src = "prebuilt/glue/android/jolt_main.c",
            mode = "reference",
        )
        # A genrule rather than a filegroup: a filegroup keeps each file at
        # its own path inside the output, so `-I` would have to name the
        # staging directory again. This hands back a directory of headers.
        native.genrule(
            name = include_name,
            out = "include",
            srcs = native.glob(["prebuilt/glue/include/*.h"]),
            cmd = "mkdir -p \"$OUT\" && cp $SRCS \"$OUT\"/",
        )
    else:
        native.genrule(
            name = c_name,
            out = "jolt_main.c",
            cmd = "cp $(location toolchains//dist:android-glue)/android/jolt_main.c \"$OUT\"",
        )
        native.genrule(
            name = include_name,
            out = "include",
            cmd = "cp -r $(location toolchains//dist:android-glue)/include \"$OUT\"",
        )
