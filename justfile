set shell := ["bash", "-euo", "pipefail", "-c"]

vidya := justfile_directory() + "/../vidya"

default:
    @just --list

# libvidya (Rust/egui build) — the tree ABI glimmer-vidya binds.
lib:
    cd {{vidya}} && just ffi

# The app. Point LD_LIBRARY_PATH at whichever libvidya build you have.
run *args:
    LD_LIBRARY_PATH="{{vidya}}/build:{{vidya}}/ffi/target/release" jolt -M:frq {{args}}
