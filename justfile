# Every recipe here is one line, because the work is in scripts/ — babashka
# scripts, run through the pin in scripts/bb. A recipe body is a shell script
# nobody can run on its own; a script in scripts/ is a script, and buck runs
# two of them as actions.

set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

# Both native libraries, cloning jolt-native at the pinned commit if needed.
lib:
    scripts/lib.bb

# buck2, with the machine's paths written where the BUCK files can read them.
buck *args:
    scripts/buck.bb {{args}}

# The APK. `just apk install` puts it on the device.
apk action="build":
    scripts/apk.bb {{action}}

# Every jolt-native pin — manifests, deps.edn, the buck table — at a release.
bump tag="":
    scripts/bump-jolt-native.bb {{tag}}

# The archives scripts/*.dotslash pins, as the table buck reads.
sync-dist:
    scripts/dotslash-to-buck

# The app.
run *args:
    scripts/run.bb {{args}}

# The same screens in a terminal. `just tui --headless` prints one screenshot.
tui *args:
    scripts/tui.bb {{args}}
