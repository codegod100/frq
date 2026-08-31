set shell := ["bash", "-euo", "pipefail", "-c"]

# Sibling checkouts, found relative to the *main* checkout rather than to this
# directory. In a git worktree they are not the same place: the justfile sits
# at .claude/worktrees/<name>, so "../jolt-native" from here would be
# .claude/worktrees/jolt-native, which is nothing. `--git-common-dir` is the one
# thing that answers the same in a worktree as it does in the checkout it came
# from.
checkout := parent_directory(`git rev-parse --path-format=absolute --git-common-dir`)

# jolt-native holds both shared objects. A sibling checkout wins, so anyone
# working on the two repos together builds what they are editing; everyone else
# gets a clone of the gitlab repo under .jolt-native, pinned to the same commit
# deps.edn takes glimmer-vidya from.
jolt_native_url := "https://gitlab.com/nandithebull/jolt-native.git"
jolt_native_sha := "70072e8e48ad396caeab6f6bd18b999cf449ec8f"
jolt_native := `
    checkout="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
    if [ -d "$checkout/../jolt-native" ]; then
        cd "$checkout/../jolt-native" && pwd
    else
        echo "$checkout/.jolt-native"
    fi
`

default:
    @just --list

# Both native libraries: libvidya (the tree ABI glimmer-vidya binds) and
# libjoltmoq (the AV media plane). One workspace, one target directory.
lib: fetch
    cd {{jolt_native}} && just build

# Clone jolt-native at the pinned commit, unless it is already here — which it
# is whenever the sibling checkout exists, since that is what jolt_native then
# points at.
[private]
fetch:
    if [ ! -d {{quote(jolt_native)}} ]; then \
        git clone {{jolt_native_url}} {{quote(jolt_native)}}; \
        cd {{quote(jolt_native)}} && git checkout --detach {{jolt_native_sha}}; \
    fi

# The app.
run *args:
    LD_LIBRARY_PATH="{{jolt_native}}/target/release" jolt -M:frq {{args}}
