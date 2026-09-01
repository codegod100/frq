# Working in this repo

## Nix

`nix` is not installed on the host. It lives in the Arch distrobox, so run every
nix command through that:

```bash
distrobox enter arch -- bash -lc 'cd <this directory> && nix build .#frq'
```

The worktree path is the same inside the container as outside, so `cd "$PWD"`
works. A remote builder (`eu.nixbuild.net`) is already configured there; the
Android outputs want `--store ssh-ng://eu.nixbuild.net --eval-store auto`, for
the reason nix/android.nix gives at the top.

One thing that container is *not* representative of: `/etc/localtime` is a
regular file there rather than a symlink, so anything that reads the zone out
of its path sees nothing. That is a real deployment shape, not an artefact —
frq.clock handles it.
