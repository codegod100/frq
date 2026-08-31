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
