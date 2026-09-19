# `dev`

    scripts/deploy dev
    modal run .modal/dev/container.py

Defined by `container.toml`; `../_loader.py` is what reads it, and
its comments are the spec.
Built on `debian:13-slim`.

Runs as a Sandbox on a real VM (kernel 6.x, not gVisor). The command
is the sandbox's own process, so it dies when the command exits --
no idle window and nothing to tear down. Note the VM restrictions:
no GPU, and memory is exactly what `[resources] memory` asks for.

No nix anywhere: the toolchain is `tools/toolchain.sh`, fetched by
pinned sha256 onto the `devshell` volume, so nothing is substituted
at build time and nothing is evaluated at start.
