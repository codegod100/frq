set shell := ["bash", "-euo", "pipefail", "-c"]

# Sibling checkouts, found relative to the *main* checkout rather than to this
# directory. In a git worktree they are not the same place: the justfile sits
# at .claude/worktrees/<name>, so "../jolt-native" from here would be
# .claude/worktrees/jolt-native, which is nothing. `--git-common-dir` is the one
# thing that answers the same in a worktree as it does in the checkout it came
# from.
checkout := parent_directory(`git rev-parse --path-format=absolute --git-common-dir`)
jolt_native := checkout / "../jolt-native"

default:
    @just --list

# Both native libraries: libvidya (the tree ABI glimmer-vidya binds) and
# libjoltmoq (the AV media plane). One workspace, one target directory.
lib:
    cd {{jolt_native}} && just build

# The app.
run *args:
    LD_LIBRARY_PATH="{{jolt_native}}/target/release" jolt -M:frq {{args}}
