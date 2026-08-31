# DotSlash, as a build artifact rather than something found on the machine.
#
# scripts/dotslash.dotslash is where the version and digest are written down,
# and it stays that way: dist/generated.bzl is derived from it by
# scripts/dotslash-to-buck, so there is one place to bump a version and no
# second copy of a digest to drift.
#
# Only DotSlash is fetched this way. jolt is not, and that is the point: what
# travels to a worker is the fetcher and the manifest, both small, and the
# worker resolves the manifest itself. See android/BUCK.
load("//dist:generated.bzl", "DIST")

def dist_archive(name, tool, platform):
    """One pinned archive, fetched by buck rather than by a shim.

    Unlike DotSlash, which resolves on the machine that runs a tool, this
    makes the archive's contents an input: their bytes are in the digest of
    every action that reads them, so a new release rebuilds what depends on
    it and an unchanged one rebuilds nothing.
    """
    entry = DIST[tool][platform]
    native.http_archive(
        name = name,
        urls = [entry["url"]],
        sha256 = entry["sha256"],
        strip_prefix = entry["strip_prefix"] or None,
        type = entry["type"],
        visibility = ["PUBLIC"],
    )

def dotslash_dist(name, platform):
    dist_archive(name, "dotslash", platform)
