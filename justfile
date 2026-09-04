# Every recipe here is one line, because the work is in scripts/ — babashka
# scripts, run through scripts/bb, which finds a bb the way this tree finds
# everything else. A recipe body is a shell script nobody can run on its own;
# a script in scripts/ is a script.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# The APK, out of the flake. `just apk install` puts it on the device.
apk action="build":
    scripts/apk.bb {{action}}

# Every jolt-native pin — nix/android.nix and deps.edn — at a release.
bump tag="":
    scripts/bump-jolt-native.bb {{tag}}

# The app: this tree's source on the flake's everything-else, in the dev shell.
run *args:
    scripts/run.bb {{args}}

# The same screens in a terminal. `just tui --headless` prints one screenshot.
tui *args:
    scripts/tui.bb {{args}}

# A jolt with the native libraries under it: a REPL, or `just repl nrepl-server`.
repl *args:
    scripts/repl.bb {{args}}
