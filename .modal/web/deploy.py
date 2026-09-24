"""The web bundle CI built, served at a URL.

    FRQ_WEB_IMAGE=ghcr.io/nandithebull/frq-web:<sha> \
        modal deploy .modal/web/deploy.py

Plain Modal, and no `container.toml` behind it. The `dev` container is
described by a spec because it is a sandbox with a volume, a toolchain and a
command that changes; this one is four constants and a `Popen`, and a spec
file for that was a second thing to read before the first one made sense.

Nothing is built here. GitHub Actions builds the image — `Dockerfile` beside this
file, two stages, the second one just the bundle and a python — and pushes it
to GHCR; this deploys that exact tag. So the thing served is
the thing that was built and tested, and a deploy is a pull rather than a
compile. The workflow is `.github/workflows/deploy.yml`.
"""

import os
import subprocess

import modal

# This file is read twice: here, by `modal deploy`, and again inside the
# container, where Modal imports it to find `serve` by name. Everything at
# module level therefore runs in both places — and the environment is not the
# same in both. `FRQ_WEB_IMAGE` is set by whoever deploys and by nobody in the
# container, so a bare `raise` here killed every container on start, the port
# never opened, and the URL hung while the deploy reported success.
#
# The tag CI just built and pushed. No default when deploying: unset, this
# fails rather than serving whatever was current the last time somebody ran
# it. In the container the tag is beside the point — the image is already the
# one that was deployed — so a placeholder stands in and is never built.
IMAGE = os.environ.get("FRQ_WEB_IMAGE", "")
if modal.is_local() and not IMAGE:
    raise SystemExit(
        "FRQ_WEB_IMAGE is unset. It is the image to serve, e.g.\n"
        "  FRQ_WEB_IMAGE=ghcr.io/nandithebull/frq-web:<sha> \\\n"
        "      modal deploy .modal/web/deploy.py"
    )

# No `registry_secret`, which is a decision rather than an omission. Modal
# pulls on every cold start — not once at deploy time — so a private image
# would need a long-lived GHCR deploy token kept as a Modal Secret, where
# the workflow's own token is short-lived by design. The image is public
# instead: it holds `build/web` and a python to serve it, and that bundle is
# what the URL hands to anyone who opens it, so a credential here would be
# guarding a copy of the public site.
#
# To go the other way, set the image private in GHCR and pass
# `secret=modal.Secret.from_name("ghcr-registry")` below, naming a Secret
# with REGISTRY_USERNAME / REGISTRY_PASSWORD for a pull-only token.
image = modal.Image.from_registry(IMAGE or "python:3.13-slim")

# Named, and the name is what makes a second deploy replace the running one
# rather than stand another beside it.
app = modal.App("frq-web", image=image)

PORT = 8000
SERVE = f"python3 /srv/webserve.py {PORT} /srv/web"


@app.function(cpu=1, memory=1024, timeout=3600, scaledown_window=300)
# One container answering many requests: a static bundle costs nothing per
# request, so scaling out on concurrency would buy cold starts and nothing
# else.
#
# No `min_containers`, which is the difference between paying for a month and
# paying for the hours anyone is here. Modal bills container uptime rather
# than requests, so a warm container held for a page nobody is reading costs
# the same as one serving it -- and this is a static bundle and a relay, with
# nothing in memory that a restart would lose. The cost of that is a cold
# start on the first hit after the window below: a registry pull of the small
# second stage and a python, seconds rather than a compile, which is what the
# two-stage Dockerfile bought.
#
# `scaledown_window` is what keeps that from being every visitor's problem.
# Five minutes of idle before shutdown means a session pays the cold start
# once and a reader clicking between channels never does -- and `/api/v1/og`
# alone, one upstream fetch per link with no caching, keeps the container
# busy for as long as anybody is actually reading.
@modal.concurrent(max_inputs=100)
# `web_server` waits for the port to accept a connection and then proxies to
# it, so the command has to keep running — `Popen` and return, not `run`.
@modal.web_server(port=PORT, startup_timeout=60)
def serve():
    subprocess.Popen(SERVE, shell=True)
