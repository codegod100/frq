# Working in this repo

## Nix

You are already running inside the Arch distrobox, where `nix` lives, so run
nix commands directly — do not wrap them in `distrobox enter`:

```bash
nix build .#frq
```

A remote builder (`eu.nixbuild.net`) is already configured here; the Android
outputs want `--store ssh-ng://eu.nixbuild.net --eval-store auto`, for the
reason nix/android.nix gives at the top.

One thing this container is *not* representative of: `/etc/localtime` is a
regular file here rather than a symlink, so anything that reads the zone out
of its path sees nothing. That is a real deployment shape, not an artefact —
frq.clock handles it.
