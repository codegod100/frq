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

# Hosts the image proxy will fetch from. An allowlist and not a wildcard: a
# proxy that fetches anything is an open proxy, and this one answers on a
# public URL.
#
# Why it exists at all: `cdn.bsky.app` serves avatars with NO
# `Access-Control-Allow-Origin` header, and Flutter web loads images through
# XHR — so the browser fetches the bytes, sees no CORS header, and throws them
# away. Nothing in the client can change that; the header is the far side's to
# send. The desktop and the APK are unaffected, because neither is a browser.
#
# `irc.freeq.at` is here for the same reason and a second one: freeq serves
# pasted images under /api/v1/media, and those are `:image` in the same chat.
PROXY_HOSTS = ("cdn.bsky.app", "irc.freeq.at", "video.bsky.app")

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

    # `http.server` with one route bolted on, rather than `-m http.server`:
    # static files are still all the app wants on first load, but images need
    # somewhere same-origin to come from. Written out and run as a file
    # because `@modal.web_server` wants a process, not a handler object.
    server = f"""
import http.server, os, socketserver, urllib.parse, urllib.request

ROOT = {WEB_ROOT!r}
HOSTS = {PROXY_HOSTS!r}

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def do_OPTIONS(self):
        # The preflight. A cross-origin image fetch does not send one, but the
        # XHRs that read freeq's API do, and answering it is two lines.
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.end_headers()

    def do_GET(self):
        if not self.path.startswith("/proxy?"):
            return super().do_GET()
        q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        target = (q.get("url") or [""])[0]
        parts = urllib.parse.urlparse(target)
        # Allowlisted https hosts only. Anything else and this is an open
        # relay wearing our origin.
        if parts.scheme != "https" or parts.hostname not in HOSTS:
            self.send_error(403, "host not proxied")
            return
        try:
            req = urllib.request.Request(target, headers={{"user-agent": "frq"}})
            with urllib.request.urlopen(req, timeout=30) as up:
                body = up.read()
                ctype = up.headers.get("content-type", "application/octet-stream")
        except Exception as e:
            self.send_error(502, f"upstream: {{e}}")
            return
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        # The whole point: our origin says yes where the far side said nothing.
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "public, max-age=3600")
        self.end_headers()
        self.wfile.write(body)

class S(socketserver.ThreadingTCPServer):
    # Threaded, because a proxied fetch blocks: one slow avatar must not stop
    # the page loading. daemon_threads so the process can still exit.
    allow_reuse_address = True
    daemon_threads = True

S(("", {PORT}), H).serve_forever()
"""
    with open("/tmp/frq_serve.py", "w") as f:
        f.write(server)

    # Popen and not run: `@modal.web_server` expects the body to *start* a
    # server and return, so Modal can begin proxying. Blocking here would time
    # out at startup_timeout with nothing ever listening.
    subprocess.Popen(["python", "/tmp/frq_serve.py"])
