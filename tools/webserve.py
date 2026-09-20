#!/usr/bin/env python3
"""Serve the web bundle, and relay the one request a browser may not make.

`python3 -m http.server` did this until the upload needed to work. freeq's
media endpoint answers `access-control-allow-origin` for exactly one origin
-- its own -- so a POST from this page is sent, accepted, and its reply
withheld by the browser. The upload happens; the URL naming it does not
come back, and a URL nobody can read is a picture nobody can see.

Nothing on the page can get around that: an `<img>` displays a
cross-origin picture without permission because displaying is not reading,
and the whole point of an upload is reading the answer.

So it is not done from the page. `/api/v1/upload` here is this server's own
path, which makes it same-origin, which means no preflight, no allowlist and
no CORS at all -- the browser is not being circumvented, it is being told
the truth. This process makes the cross-origin request, where the rule does
not apply, and hands back what came.

Two things this is deliberately not. It is not a general proxy: one path,
one method, one upstream, fixed here rather than taken from the request, so
it cannot be pointed at anything. And it is not a permanent answer -- one
`Access-Control-Allow-Origin: *` on a public, unauthenticated endpoint would
retire it, and that ask is now the small one because the page sends no
credentials.

    python3 tools/webserve.py [PORT] [DIRECTORY]

`FRQ_API_ORIGIN` names the freeq to relay to, for anyone running their own.
"""

import os
import sys
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("FRQ_API_ORIGIN", "https://irc.freeq.at").rstrip("/")
UPLOAD = "/api/v1/upload"

# The endpoint's own cap. Refused here rather than after twelve megabytes
# have crossed this machine on their way to being turned down.
LIMIT = 12 * 1024 * 1024


class Handler(SimpleHTTPRequestHandler):
    # `http.server` answers HTTP/1.0 and closes the connection after every
    # response, which is a new one for each of the fifteen-odd files a load
    # asks for. The base class already sends an accurate Content-Length,
    # which is what 1.1 needs to be honest about, so keep-alive costs
    # nothing here.
    #
    # It was tried first as a guess at why the preview browser would not
    # register a service worker, and it was not the reason -- that browser
    # refuses whatever it is served. Kept because connection reuse is worth
    # having on its own, not because it fixed anything.
    protocol_version = "HTTP/1.1"

    def end_headers(self):
        """Revalidate everything, because no name here promises anything.

        A deploy changed what was served and browsers went on showing what
        they had -- twice in one afternoon a fix looked broken because the
        page was yesterday's. Flutter stamps a fresh `serviceWorkerVersion`
        so the new worker does download, but the spec leaves it *waiting*
        until every tab on the origin is closed; reloading does not do it,
        and the cure was clearing the site's data by hand.

        The usual answer -- cache the hashed assets forever, revalidate the
        few files with stable names -- does not apply, because nothing in
        this bundle is hashed. `main.dart.js`, `frq_core.js`,
        `flutter_bootstrap.js` and the rest keep their names and change
        their contents on every deploy, so a name here says nothing about
        what is behind it.

        `no-cache` is not `no-store`: the copy is kept and revalidated, so
        an unchanged file costs a conditional GET and comes back 304 with
        no body. A round trip per file, against a fix that does not arrive.
        """
        path = self.path.split("?")[0]
        if not path.startswith(UPLOAD):
            self.send_header("Cache-Control", "no-cache")
        SimpleHTTPRequestHandler.end_headers(self)

    def do_POST(self):
        if self.path.split("?")[0] != UPLOAD:
            self.send_error(404, "Not Found")
            return

        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > LIMIT:
            # Drained before it is refused, and the draining is the point.
            # Answering 413 and closing on a sender still writing gives it a
            # broken pipe instead of the sentence explaining why -- so the
            # bytes are read and dropped, up to a bound past which nobody is
            # owed an explanation.
            if 0 < length <= LIMIT * 4:
                left = length
                while left > 0:
                    chunk = self.rfile.read(min(left, 65536))
                    if not chunk:
                        break
                    left -= len(chunk)
            else:
                self.close_connection = True
            self.send_error(413, "Body too large")
            return

        # `Content-Type` carries the multipart boundary, so the body is
        # unreadable without it. Nothing else is forwarded: no cookies, no
        # Authorization, nothing this server was trusted with.
        req = urllib.request.Request(
            UPSTREAM + UPLOAD,
            data=self.rfile.read(length),
            method="POST",
            headers={"Content-Type": self.headers.get("Content-Type", "")},
        )
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                status, body, kind = r.status, r.read(), r.headers.get_content_type()
        except urllib.error.HTTPError as e:
            # freeq's own refusal, passed through with its reason. Turning
            # every one of these into a 502 would lose the message that says
            # what was wrong with the file.
            status, body, kind = e.code, e.read(), "application/json"
        except OSError as e:
            status, body, kind = 502, str(e).encode(), "text/plain"

        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))


def main() -> None:
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8000
    directory = sys.argv[2] if len(sys.argv) > 2 else "build/web"
    handler = partial(Handler, directory=directory)
    srv = ThreadingHTTPServer(("", port), handler)
    print(f"serving {directory} on http://localhost:{port}"
          f" ({UPLOAD} relays to {UPSTREAM})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
