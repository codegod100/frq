#!/usr/bin/env python3
"""The server that carries the upload across the origin boundary.

    python3 nim/web/test/serve.py

Offline: the upstream is a stub in this process, so nothing is uploaded
anywhere. What is checked is the part with teeth -- that it relays the one
path and is not a proxy for anything else.
"""
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))
seen = {}


class Upstream(BaseHTTPRequestHandler):
    def do_GET(self):
        seen["get_path"] = self.path
        seen["get_accept"] = self.headers.get("Accept")
        seen["get_agent"] = self.headers.get("User-Agent")
        if self.path.startswith("/api/v1/og?"):
            self.send_response(502 if "broken" in self.path else 200)
            out = (b'{"title":"A page"}' if "broken" not in self.path
                   else b'{"error":"fetch failed"}')
        elif self.path.startswith("/xrpc/app.bsky.actor.getProfile?"):
            self.send_response(400 if "missing" in self.path else 200)
            out = (b'{"did":"did:plc:ok","displayName":"A reader"}'
                   if "missing" not in self.path else b'{"error":"not found"}')
        else:
            self.send_response(404)
            out = b""
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        seen["path"] = self.path
        seen["body"] = self.rfile.read(n)
        seen["type"] = self.headers.get("Content-Type")
        seen["cookie"] = self.headers.get("Cookie")
        if b"boom" in seen["body"]:
            out = json.dumps({"error": "Bad Request"}).encode()
            self.send_response(400)
        else:
            out = json.dumps({"url": "https://media.example/p.png"}).encode()
            self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def post(url, body, headers=None):
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def main():
    up = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    threading.Thread(target=up.serve_forever, daemon=True).start()
    origin = "http://127.0.0.1:%d" % up.server_address[1]

    www = os.path.join(ROOT, "nim", "web", "test")
    env = dict(os.environ, FRQ_API_ORIGIN=origin, FRQ_PROFILE_ORIGIN=origin)
    proc = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "tools", "webserve.py"),
         "8732", www],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    base = "http://127.0.0.1:8732"
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(base + "/serve.py", timeout=1).read()
                break
            except OSError:
                time.sleep(0.1)

        ok = lambda s: print("  ok   " + s)

        # Still a file server: the bundle is the reason it exists.
        with urllib.request.urlopen(base + "/serve.py", timeout=5) as r:
            assert b"across the origin boundary" in r.read()
        ok("it still serves the bundle")

        # Every name in this bundle is stable and its contents change on
        # every deploy, so a cached copy is a stale one and the browser has
        # no way to know. `no-cache` keeps the copy and revalidates it.
        with urllib.request.urlopen(base + "/serve.py", timeout=5) as r:
            assert r.headers.get("Cache-Control") == "no-cache", \
                r.headers.get("Cache-Control")
        ok("and asks the browser to revalidate what it serves")

        # A conditional request still answers 304, which is the whole reason
        # this costs a round trip rather than a download.
        req = urllib.request.Request(base + "/serve.py", headers={
            "If-Modified-Since": r.headers.get("Last-Modified")})
        code = 0
        try:
            with urllib.request.urlopen(req, timeout=5) as r2:
                code = r2.status
        except urllib.error.HTTPError as e:
            code = e.code
        assert code == 304, code
        ok("and an unchanged file comes back 304, with no body")

        # The relay, with the body and its multipart boundary intact --
        # without the Content-Type the body is unreadable at the far end.
        status, body = post(base + "/api/v1/upload", b"--b\r\npicture\r\n--b--",
                            {"Content-Type": "multipart/form-data; boundary=b"})
        assert status == 200, status
        assert json.loads(body)["url"] == "https://media.example/p.png"
        assert seen["path"] == "/api/v1/upload"
        assert seen["body"] == b"--b\r\npicture\r\n--b--"
        assert seen["type"] == "multipart/form-data; boundary=b"
        ok("an upload reaches the far end whole, and the URL comes back")

        # A refusal is freeq's to explain. A 502 in its place would lose the
        # sentence saying what was wrong with the file.
        status, body = post(base + "/api/v1/upload", b"boom",
                            {"Content-Type": "multipart/form-data; boundary=b"})
        assert status == 400, status
        assert json.loads(body)["error"] == "Bad Request"
        ok("and a refusal keeps its reason")

        # Nothing this server was trusted with is handed on.
        post(base + "/api/v1/upload", b"x",
             {"Content-Type": "text/plain", "Cookie": "session=secret"})
        assert seen["cookie"] is None, seen["cookie"]
        ok("a cookie of ours is not forwarded")

        # Link and profile failures are ordinary optional-content misses.
        # They remain visible in the relay log, but a successful empty
        # response keeps browsers from reporting handled failures as broken
        # page resources in their console.
        with urllib.request.urlopen(
                base + "/api/v1/og?url=https%3A%2F%2Fbroken.example",
                timeout=5) as r:
            assert r.status == 204, r.status
            assert r.read() == b""
        with urllib.request.urlopen(
                base + "/api/v1/profile?actor=missing.example",
                timeout=5) as r:
            assert r.status == 204, r.status
            assert r.read() == b""
        ok("optional preview and profile misses are quiet empty responses")

        # Obvious SSRF and malformed-input cases stop at this process rather
        # than spending a request and a rate-limit slot at freeq.  DNS names
        # remain freeq's check because that is where they are resolved for
        # the actual page fetch.
        for target in (
                "http://127.0.0.1/private",
                "http://[::1]/private",
                "http://localhost/private",
                "file:///etc/passwd",
                "not a URL"):
            try:
                urllib.request.urlopen(
                    base + "/api/v1/og?" + urllib.parse.urlencode({"url": target}),
                    timeout=5)
                raise AssertionError("invalid preview URL was accepted: " + target)
            except urllib.error.HTTPError as e:
                assert e.code == 400, (target, e.code)
        ok("invalid and local preview URLs are refused before the upstream")

        with urllib.request.urlopen(
                base + "/api/v1/og?url=https%3A%2F%2Fheaders.example",
                timeout=5) as r:
            assert r.status == 200, r.status
        assert seen["get_accept"] == "application/json", seen["get_accept"]
        assert seen["get_agent"] == "frq-web-preview/1", seen["get_agent"]
        ok("preview requests identify the relay and ask for JSON")

        with urllib.request.urlopen(
                base + "/api/v1/profile?actor=did%3Aplc%3Aok", timeout=5) as r:
            assert r.status == 200, r.status
            assert json.loads(r.read())["did"] == "did:plc:ok"
        assert seen["get_path"].endswith("actor=did%3Aplc%3Aok")
        ok("a profile is relayed through the fixed public endpoint")

        # One path. Not a proxy.
        status, _ = post(base + "/api/v1/search", b"x")
        assert status == 404, status
        status, _ = post(base + "/", b"x")
        assert status == 404, status
        ok("and no other path is relayed at all")

        # The endpoint's own cap, refused before it crosses this machine.
        status, _ = post(base + "/api/v1/upload", b"x" * (12 * 1024 * 1024 + 1),
                         {"Content-Type": "multipart/form-data; boundary=b"})
        assert status == 413, status
        ok("something over the limit is turned down here")

        print("all ok")
    finally:
        proc.terminate()
        up.shutdown()


if __name__ == "__main__":
    main()
