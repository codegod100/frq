"""The web bundle CI built, served at a URL.

    FRQ_WEB_IMAGE=registry.rickub.com/nandi/frq-web:<sha> \
        modal deploy .modal/web/app.py

Plain Modal, and no `container.toml` behind it. The `dev` container is
described by a spec because it is a sandbox with a volume, a toolchain and a
command that changes; this one is four constants and a `Popen`, and a spec
file for that was a second thing to read before the first one made sense.

Nothing is built here. rickub builds the image — `Dockerfile` beside this
file, two stages, the second one just the bundle and a python — and pushes it
to `registry.rickub.com`; this deploys that exact tag. So the thing served is
the thing that was built and tested, and a deploy is a pull rather than a
compile. The workflow is `.rickub/workflows/web.yml`.
"""

import os
import subprocess

import modal

# The tag CI just built and pushed. No default: unset, this fails here rather
# than deploying whatever was current the last time somebody ran it.
IMAGE = os.environ.get("FRQ_WEB_IMAGE", "")
if not IMAGE:
    raise SystemExit(
        "FRQ_WEB_IMAGE is unset. It is the image to serve, e.g.\n"
        "  FRQ_WEB_IMAGE=registry.rickub.com/nandi/frq-web:<sha> \\\n"
        "      modal deploy .modal/web/app.py"
    )

# No `registry_secret`, which is a decision rather than an omission. Modal
# pulls on every cold start — not once at deploy time — so a private image
# would need a long-lived rickub deploy token kept as a Modal Secret, where
# the workflow's own token is short-lived by design. The image is public
# instead: it holds `build/web` and a python to serve it, and that bundle is
# what the URL hands to anyone who opens it, so a credential here would be
# guarding a copy of the public site.
#
# To go the other way, set the image private on rickub and pass
# `secret=modal.Secret.from_name("rickub-registry")` below, naming a Secret
# with REGISTRY_USERNAME / REGISTRY_PASSWORD for a pull-only token.
image = modal.Image.from_registry(IMAGE)

# Named, and the name is what makes a second deploy replace the running one
# rather than stand another beside it.
app = modal.App("frq-web", image=image)

PORT = 8000
SERVE = f"python3 -m http.server {PORT} --directory /srv/web"


@app.function(cpu=1, memory=1024, timeout=3600, min_containers=1)
# One container answering many requests: a static bundle costs nothing per
# request, so scaling out on concurrency would buy cold starts and nothing
# else.
@modal.concurrent(max_inputs=100)
# `web_server` waits for the port to accept a connection and then proxies to
# it, so the command has to keep running — `Popen` and return, not `run`.
@modal.web_server(port=PORT, startup_timeout=60)
def serve():
    subprocess.Popen(SERVE, shell=True)
