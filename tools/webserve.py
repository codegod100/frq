#!/usr/bin/env python3
"""Serve the web bundle, and relay the two requests a browser may not make.

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

`/api/v1/og` is here for the same reason and was found the same way: link
previews shipped asking freeq directly, every fetch was blocked by the
allowlist, and on the screen that read as a feature that simply did nothing.
The difference from the upload is only which way the bytes go -- a GET with
the page's `?url=` passed through, and the OpenGraph JSON handed back.

Two things this is deliberately not. It is not a general proxy: two paths,
one method each, one upstream, fixed here rather than taken from the
request, so it cannot be pointed at anything. The `url` a caller passes is
freeq's business, not this server's -- it is the one that fetches it, and it
resolves the host and refuses the private ranges before it does.

And it is not a permanent answer -- one `Access-Control-Allow-Origin: *` on
a public, unauthenticated endpoint would retire both, and that ask is now
the small one because the page sends no credentials.

    python3 tools/webserve.py [PORT] [DIRECTORY]

`FRQ_API_ORIGIN` names the freeq to relay to, for anyone running their own.
"""

import os
import sys
import threading
import time
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("FRQ_API_ORIGIN", "https://irc.freeq.at").rstrip("/")
UPLOAD = "/api/v1/upload"
OG = "/api/v1/og"

# The endpoint's own cap. Refused here rather than after twelve megabytes
# have crossed this machine on their way to being turned down.
LIMIT = 12 * 1024 * 1024

# What a link turned out to be, kept for a while.
#
# This is not a speed optimisation, it is a fairness one. Every reader's
# previews leave from this one process, so freeq sees one address for all of
# them and rate-limits accordingly -- and uncached, a single page load asks
# for a preview per link on screen, every time it is opened. One reader
# scrolling a link-heavy backlog could spend the budget for everybody, and
# what that looks like on the screen is somebody else's previews quietly
# turning into 429s.
#
# An OpenGraph title is not news. A day is far inside how often one changes
# and far outside how often a backlog is re-read, which is the pair of
# numbers that matters -- and a stale card is a smaller wrong answer than an
# absent one.
#
# Bounded, because this process is long-lived and a cache that only grows is
# a slower leak rather than not one. At the cap the oldest third goes: enough
# that eviction is rare rather than continuous, and `dict` preserves
# insertion order, so "oldest" needs no bookkeeping of its own.
#
# Failures are cached too, for much less time. A host that is down is down
# for the next reader a minute from now, and retrying it per page load is
# how one dead link in a backlog becomes the thing spending the budget.
OG_TTL = 24 * 60 * 60
OG_FAIL_TTL = 60
OG_MAX = 2048

_og_cache: dict[str, tuple[float, int, bytes, str]] = {}
_og_lock = threading.Lock()


def og_cached(query):
    """The stored answer for this query, or None."""
    with _og_lock:
        hit = _og_cache.get(query)
        if hit is None:
            return None
        expires, status, body, kind = hit
        if expires < time.monotonic():
            # Expired rather than absent: dropped here so a URL nobody asks
            # for again does not sit in the table until the cap evicts it.
            del _og_cache[query]
            return None
        return status, body, kind


def og_remember(query, status, body, kind):
    ttl = OG_TTL if status == 200 else OG_FAIL_TTL
    with _og_lock:
        if len(_og_cache) >= OG_MAX:
            for stale in list(_og_cache)[: OG_MAX // 3]:
                del _og_cache[stale]
        _og_cache[query] = (time.monotonic() + ttl, status, body, kind)


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
        if path == OG:
            # The one thing here that may be held without revalidating. A
            # bundle file is a name whose contents change on every deploy;
            # a preview is a URL's OpenGraph tags, which are not about this
            # client at all and do not change because we shipped. An hour in
            # the browser is a reload, a tab restore and a second visit that
            # ask this server nothing -- and this server is where every
            # reader's requests converge into the one address freeq counts.
            #
            # Shorter than the table's own day, deliberately: what a browser
            # holds cannot be dropped when it turns out to be wrong, and an
            # hour is the length of a sitting rather than of a habit.
            self.send_header("Cache-Control", "max-age=3600")
        elif path != UPLOAD:
            self.send_header("Cache-Control", "no-cache")
        SimpleHTTPRequestHandler.end_headers(self)

    def do_GET(self):
        """The bundle, or the preview relay.

        Everything but one path is a file, so the base class answers first
        and this only steps in front of it.
        """
        if self.path.split("?")[0] != OG:
            SimpleHTTPRequestHandler.do_GET(self)
            return

        query = self.path.split("?", 1)[1] if "?" in self.path else ""
        if not query.startswith("url="):
            self.send_error(400, "url is required")
            return

        # Answered from the table where it is there, which is most of the
        # time: a backlog is re-read far more often than a page's OpenGraph
        # tags change. The query string is the key rather than the decoded
        # URL -- it is what would be sent upstream, so two requests sharing
        # it share an answer by construction.
        hit = og_cached(query)
        if hit is not None:
            status, body, kind = hit
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        # Nothing of the caller's is forwarded -- no cookies, no
        # Authorization, nothing this server was trusted with. The query is
        # already encoded by whoever built it and is passed through as it
        # came, since re-encoding it here would be a second opinion about
        # what the URL was.
        req = urllib.request.Request(
            UPSTREAM + OG + "?" + query, method="GET",
        )
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                status, body, kind = r.status, r.read(), r.headers.get_content_type()
        except urllib.error.HTTPError as e:
            # freeq's own refusal, passed through with its reason -- "Body
            # too large" for a page over its cap, "Blocked" for a host it
            # will not resolve. A 502 in place of those would lose the only
            # sentence saying what happened.
            status, body, kind = e.code, e.read(), "application/json"
        except OSError as e:
            status, body, kind = 502, str(e).encode(), "text/plain"

        # A 429 is never stored. It is not what this link is, it is what
        # freeq thought of us a moment ago -- and keeping it would turn one
        # exhausted budget into a day of blank cards for a link that was
        # fine.
        if status != 429:
            og_remember(query, status, body, kind)

        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
          f" ({UPLOAD} and {OG} relay to {UPSTREAM})", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
