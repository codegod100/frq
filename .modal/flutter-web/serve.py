"""The built web app, served from the volume the container built it into.

Not part of `container.py`, and not a key in `container.toml`, because it is
the other half of a split the build already makes: the Sandbox compiles into
`/devshell/frq-flutter-web` and exits, and what it leaves behind is a
directory of static files that outlives it. A Function mounting the same
volume can hand those out without rebuilding anything, and can scale to zero
between readers -- which a Sandbox holding a tunnel open cannot.

    modal serve .modal/flutter-web/serve.py     # while editing, auto-reloads
    modal deploy .modal/flutter-web/serve.py    # a URL that stays

Deliberately NOT built on the container's own image. That image carries the
repo and a few gigabytes of devShell closure, all of it for a compile that
has already happened somewhere else; the bytes this serves come off the
volume, so the image needs a python and nothing more. Cold starts are the
difference.
"""

import json
import subprocess

import modal

# The same volume the container writes to, named the same way. `from_name` is
# lazy, so naming it here costs nothing until a container actually mounts it.
DEVSHELL = modal.Volume.from_name("devshell", create_if_missing=True)

# Where `just flutter-web` leaves its output, under this devShell's own
# directory on the shared volume -- the same path container.toml builds in.
WEB_ROOT = "/devshell/frq-flutter-web/flutter/build/web"

PORT = 8080

# This app's own origin, and the one thing here that is not derivable: an
# OAuth client_id in AT Protocol *is* the URL its metadata is served from, so
# the document has to name the origin it will be fetched from. Modal's
# deployed URL is stable for a given app name, which is what makes that safe
# to write down.
ORIGIN = "https://codegod100--frq-flutter-web-serve-web.modal.run"

# The OAuth client identity, served at `/client-metadata.json`.
#
# This is what makes Bluesky sign-in possible from this origin at all. freeq's
# auth broker will only redirect to hosts on its own allowlist, and this one is
# not among them -- but a client that runs the OAuth flow *itself* is not asking
# the broker for anything. An AT Protocol authorization server fetches this
# document from the client_id URL and takes it as the authority on where a code
# may be sent, so the allowlist that matters is the `redirect_uris` below, which
# we publish.
#
# A public client: `token_endpoint_auth_method: none` and no secret, because a
# page in a browser can keep none. What stands in for one is DPoP -- every token
# is bound to a key the client proves it holds, which is also exactly what
# freeq's SASL `pds-oauth` method verifies.
CLIENT_METADATA = {
    "client_id": f"{ORIGIN}/client-metadata.json",
    "client_name": "frq",
    "client_uri": f"{ORIGIN}/",
    "redirect_uris": [f"{ORIGIN}/"],
    "grant_types": ["authorization_code", "refresh_token"],
    "response_types": ["code"],
    # `atproto` is the identity scope freeq needs; `transition:generic` is what
    # a PDS still wants for ordinary reads and writes.
    "scope": "atproto transition:generic",
    "token_endpoint_auth_method": "none",
    "application_type": "web",
    "dpop_bound_access_tokens": True,
}

app = modal.App("frq-flutter-web-serve")

image = modal.Image.debian_slim(python_version="3.12")


@app.function(
    image=image,
    volumes={"/devshell": DEVSHELL},
    # Nothing here holds state between requests, and a reader who wanders off
    # should stop costing anything -- so let it go to zero quickly rather than
    # keeping a container warm for a static directory.
    scaledown_window=60,
)
@modal.web_server(PORT, startup_timeout=30)
def web():
    # A Volume mount is a snapshot taken when the container starts, so a
    # container that outlives a build would keep serving the old one. Reload
    # first and the newest committed build is what gets served -- which is the
    # whole point of the split: rebuild in the Sandbox, and the next cold
    # start here picks it up with nothing redeployed.
    DEVSHELL.reload()

    # The client metadata is written beside the bundle rather than served by a
    # route of its own: `http.server` has no routing table, and one file on
    # disk is less machinery than a handler subclass. Written at start-up and
    # not baked into the build, because it names the deployed origin, which is
    # a property of this Function and not of the ClojureDart.
    #
    # The volume is shared and durable, so this also survives for the next
    # cold start; rewriting it every time is what keeps ORIGIN and the file in
    # step when one of them changes.
    with open(f"{WEB_ROOT}/client-metadata.json", "w") as f:
        json.dump(CLIENT_METADATA, f, indent=2)
    DEVSHELL.commit()

    # Popen and not run: `@modal.web_server` expects the body to *start* a
    # server and return, so Modal can begin proxying. Blocking here would time
    # out at startup_timeout with nothing ever listening.
    #
    # `python -m http.server` and not something with a routing table: Flutter
    # writes a service worker and an index.html and asks for its own assets by
    # exact path, so plain static serving is all the app wants on first load.
    # What it does not give is a fallback for a deep link -- Flutter's default
    # URL strategy is real paths, so /chats reaches the server rather than the
    # router and gets a 404. That wants a real fallback-to-index server, and
    # is worth having only once there is a router out there to reach.
    subprocess.Popen(
        ["python", "-m", "http.server", str(PORT), "--directory", WEB_ROOT],
    )
