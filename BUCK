# The Jolt sources the boot image is compiled from. Named as a target so that
# editing a screen invalidates the image: the compile itself reads the tree
# through deps.edn paths rather than through these, but buck only reruns it
# when something here changes.
filegroup(
    name = "jolt-sources",
    srcs = glob(["src/**/*.jolt", "src/**/*.edn"]) + ["deps.edn"],
    visibility = ["PUBLIC"],
)

alias(
    name = "apk",
    actual = "//android:apk",
    visibility = ["PUBLIC"],
)
