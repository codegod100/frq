set shell := ["bash", "-euo", "pipefail", "-c"]

# Sibling checkouts, found relative to the *main* checkout rather than to this
# directory. In a git worktree they are not the same place: the justfile sits
# at .claude/worktrees/<name>, so "../vidya" from here would be
# .claude/worktrees/vidya, which is nothing. `--git-common-dir` is the one
# thing that answers the same in a worktree as it does in the checkout it came
# from.
checkout := parent_directory(`git rev-parse --path-format=absolute --git-common-dir`)
vidya := checkout / "../vidya"
jolt_native := checkout / "../jolt-native"

default:
    @just --list

# libvidya (Rust/egui build) — the tree ABI glimmer-vidya binds.
lib:
    cd {{vidya}} && just ffi

# libjoltmoq — the AV media plane. Only needed for calls; everything else in
# the client runs without it.
av:
    cd {{jolt_native}} && just build

# The app. Point LD_LIBRARY_PATH at whichever libvidya build you have.
run *args:
    LD_LIBRARY_PATH="{{vidya}}/build:{{vidya}}/ffi/target/release:{{jolt_native}}/target/release" jolt -M:frq {{args}}
