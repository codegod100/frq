# Every recipe here is one line, because the work is in scripts/ — babashka
# scripts, run through the pin in scripts/bb. A recipe body is a shell script
# nobody can run on its own; a script in scripts/ is a script.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Both native libraries, out of the release pins. `run` builds them instead.
lib:
    scripts/lib.bb

# The APK, out of the flake. `just apk install` puts it on the device.
apk action="build":
    scripts/apk.bb {{action}}

# Every jolt-native pin — the manifests, deps.edn, nix/android.nix — at a release.
bump tag="":
    scripts/bump-jolt-native.bb {{tag}}

# The app: this tree's source on the flake's everything-else, in the dev shell.
run *args:
    scripts/run.bb {{args}}
