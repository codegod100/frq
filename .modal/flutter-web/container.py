"""Generated stub -- the container is defined by container.toml.

Edit container.toml, not this file.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from _loader import Container  # noqa: E402

c = Container.from_toml(__file__)
image, app = c.image, c.app


# No @app.function here: a Sandbox runs its command as its own process and
# nothing of this module is imported into it. Registering a Function would be
# dead weight, and its kwargs are where vm_runtime would be wrongly applied.
# One entrypoint, not two: a second `@app.local_entrypoint` makes plain
# `modal run container.py` ambiguous, and Modal refuses it rather than
# picking. `--shell` is a flag on the one there is.
@app.local_entrypoint()
def main(command: str = "", shell: bool = False):
    if not shell:
        c.run_sandbox(command)
        return

    # `modal shell --image` only takes registry references, so it cannot be
    # pointed at a published Modal image like arch-nix. Attaching to a running
    # Sandbox can, and that Sandbox is this container: same image, same
    # volumes, same env.
    sb = c.open_sandbox()
    print(f"sandbox {sb.object_id} up, with {', '.join(c.volumes) or 'no volumes'}")
    print(f"  attach: modal shell {sb.object_id}   (from another terminal)")
    print("Ctrl-C here takes it down.")
    # Blocks on `sleep infinity`, which is the point: an ephemeral app stops
    # when its local entrypoint returns, and stopping the app terminates the
    # Sandbox with it -- so returning here would leave nothing to attach to.
    try:
        sb.wait()
    except KeyboardInterrupt:
        print("terminating")
        sb.terminate()
