set shell := ["bash", "-euo", "pipefail", "-c"]

vidya := justfile_directory() + "/../vidya"
jolt_native := justfile_directory() + "/../jolt-native"

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
