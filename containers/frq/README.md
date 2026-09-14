# `frq`

    scripts/deploy frq
    modal run containers/frq/container.py

Defined by `container.toml`; see `../spec.md` for the keys.
Built on the published `arch-nix` image.

Runs as a Sandbox on a real VM (kernel 6.x, not gVisor). The command
is the sandbox's own process, so it dies when the command exits --
no idle window and nothing to tear down. Note the VM restrictions:
no GPU, and memory is exactly what `[resources] memory` asks for.

No nix at run time: nothing is substituted at build time and nothing
is evaluated at start. Add a `flake.nix` and set `[nix] flake`/`shim`
together if you want a devShell, knowing what it costs.
