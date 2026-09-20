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
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))
seen = {}


class Upstream(BaseHTTPRequestHandler):
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
    env = dict(os.environ, FRQ_API_ORIGIN=origin)
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
