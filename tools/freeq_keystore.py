#!/usr/bin/env python3
"""A freeq account's app password in the desktop keystore, and a reader for it.

    freeq_keystore.py store                 prompt for handle + app password,
                                            check them, put them in the keystore
    freeq_keystore.py around '#room' MSGID  print the raw IRC lines around one
                                            message, tags and all

`store` is the only thing that writes, and it is for a person at a terminal:
the password is read with echo off and handed to `secret-tool` on stdin, so it
is never in an argument, an environment variable or a file.

Everything else only reads it. `around` signs in the way the app does (handle
-> DID -> PDS -> createSession, then SASL `pds-session` at freeq), joins the
room, asks for `CHATHISTORY AROUND msgid=…`, prints what comes back and quits.
It never sends a PRIVMSG or a TAGMSG, and never prints the password, the
session token or an AUTHENTICATE line.

The keystore is libsecret (GNOME Keyring, KWallet's Secret Service bridge),
through `secret-tool`, so there is nothing to pip install.

Only an app password, never the account's main one: it is a credential that
cannot change the account and can be revoked on its own.
"""

from __future__ import annotations

import argparse
import base64
import getpass
import json
import re
import socket
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SERVICE = "frq"
APP_PASSWORD = re.compile(r"[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}")
DIRECTORY = "https://public.api.bsky.app"
PLC = "https://plc.directory"
TIMEOUT = 15
CAPS = ["message-tags", "server-time", "batch", "draft/chathistory",
        "account-tag", "echo-message", "freeq.at/act", "sasl"]


# ------------------------------------------------------------------ keystore

def keystore_read(key: str) -> str:
    """One secret out of the keystore, or exit saying how to put it there."""
    try:
        out = subprocess.run(["secret-tool", "lookup", "service", SERVICE,
                              "key", key],
                             capture_output=True, text=True, check=False)
    except FileNotFoundError:
        sys.exit("secret-tool is not installed (libsecret-tools / libsecret)")
    if out.returncode != 0 or not out.stdout:
        sys.exit(f"nothing stored for {key}; run: {sys.argv[0]} store")
    return out.stdout.rstrip("\n")


def keystore_write(key: str, label: str, value: str) -> None:
    subprocess.run(["secret-tool", "store", "--label", label,
                    "service", SERVICE, "key", key],
                   input=value, text=True, check=True)


# ------------------------------------------------------------------- atproto

def fetch_json(url: str, body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        try:
            message = json.load(error).get("message", "")
        except ValueError:
            message = ""
        raise SystemExit(f"{url.split('?')[0]}: {message or error}") from None


def create_session(handle: str, password: str) -> dict:
    """The PDS's session for this handle: {did, handle, accessJwt, pds}."""
    did = fetch_json(f"{DIRECTORY}/xrpc/com.atproto.identity.resolveHandle?"
                     + urllib.parse.urlencode({"handle": handle}))["did"]
    if did.startswith("did:plc:"):
        doc = fetch_json(f"{PLC}/{did}")
    elif did.startswith("did:web:"):
        doc = fetch_json(f"https://{did[len('did:web:'):]}/.well-known/did.json")
    else:
        raise SystemExit(f"unsupported DID method: {did}")
    pds = next(s["serviceEndpoint"] for s in doc.get("service", [])
               if s.get("id", "").endswith("#atproto_pds"))
    session = fetch_json(f"{pds.rstrip('/')}/xrpc/com.atproto.server.createSession",
                         {"identifier": handle, "password": password})
    return {"did": session.get("did", did), "handle": session.get("handle", handle),
            "accessJwt": session["accessJwt"], "pds": pds}


# ----------------------------------------------------------------------- irc

def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def b64url_decode(text: str) -> bytes:
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


class Irc:
    def __init__(self, host: str, port: int):
        raw = socket.create_connection((host, port), timeout=TIMEOUT)
        self.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
        self.buf = b""

    def send(self, line: str, quiet: bool = False) -> None:
        if not quiet:
            print(f">> {line}", flush=True)
        self.sock.sendall(line.encode() + b"\r\n")

    def lines(self):
        while True:
            while b"\r\n" not in self.buf:
                chunk = self.sock.recv(65536)
                if not chunk:
                    return
                self.buf += chunk
            line, self.buf = self.buf.split(b"\r\n", 1)
            yield line.decode(errors="replace")


def split(line: str) -> tuple[str, str, list[str]]:
    """(tags, command, params) — enough of RFC 1459 to steer a handshake."""
    tags = ""
    if line.startswith("@"):
        tags, _, line = line.partition(" ")
    if line.startswith(":"):
        _, _, line = line.partition(" ")
    head, _, trailing = line.partition(" :")
    parts = head.split()
    params = parts[1:] + ([trailing] if trailing or " :" in line else [])
    return tags, (parts[0] if parts else ""), params


def around(room: str, msgid: str, limit: int, host: str, port: int,
           settle: float) -> None:
    handle = keystore_read("handle")
    session = create_session(handle, keystore_read("app-password"))
    print(f"-- signed in at the PDS as {session['handle']} ({session['did']})",
          flush=True)

    irc = Irc(host, port)
    nick = session["handle"]
    irc.send("CAP LS 302")
    irc.send(f"NICK {nick}")
    irc.send(f"USER {nick.split('.')[0]} 0 * :frq read-only probe")

    registered = False
    asked = False
    done_at: float | None = None
    irc.sock.settimeout(1.0)
    it = irc.lines()
    while True:
        try:
            line = next(it)
        except StopIteration:
            break
        except (socket.timeout, TimeoutError):
            if done_at is not None and time.time() >= done_at:
                break
            continue
        tags, cmd, params = split(line)
        if cmd == "PING":
            irc.send("PONG :" + (params[-1] if params else ""), quiet=True)
            continue
        if cmd != "AUTHENTICATE":
            print(f"<< {line}", flush=True)

        if cmd == "CAP" and len(params) >= 2:
            sub = params[1]
            if sub == "LS" and not (len(params) >= 3 and params[2] == "*"):
                offered = {c.split("=")[0] for c in params[-1].split()}
                irc.send("CAP REQ :" + " ".join(c for c in CAPS if c in offered))
            elif sub == "ACK":
                irc.send("AUTHENTICATE ATPROTO-CHALLENGE"
                         if "sasl" in params[-1].split() else "CAP END")
            elif sub == "NAK":
                irc.send("CAP END")
        elif cmd == "AUTHENTICATE":
            print("<< AUTHENTICATE (challenge, not shown)", flush=True)
            nonce = json.loads(b64url_decode(params[0])).get("nonce", "")
            payload = b64url(json.dumps({
                "did": session["did"], "signature": session["accessJwt"],
                "method": "pds-session", "pds_url": session["pds"],
                "challenge_nonce": nonce}).encode())
            print(">> AUTHENTICATE (pds-session, not shown)", flush=True)
            # One line, not the IRCv3 400-byte chunks: freeq decodes the
            # single param it is handed and does not reassemble (see
            # `saslChunk` in nim/src/frq/handshake.nim).
            irc.send(f"AUTHENTICATE {payload}", quiet=True)
        elif cmd in ("903", "904", "905", "906"):
            if cmd != "903":
                sys.exit("-- freeq refused the sign-in; stopping rather than "
                         "reading as a guest")
            irc.send("CAP END")
        elif cmd in ("001",) and not registered:
            registered = True
            irc.send(f"JOIN {room}")
        elif (cmd == "366" and not asked and len(params) > 1
              and params[1].lower() == room.lower()):
            asked = True
            irc.send(f"CHATHISTORY AROUND {room} msgid={msgid} {limit}")
            done_at = time.time() + settle
        elif (cmd in ("473", "474", "475", "403", "405") and len(params) > 1
              and params[1].lower() == room.lower()):
            # Only for this room: freeq joins an account to its own rooms at
            # registration, and one of those refusing is not ours to stop on.
            sys.exit(f"-- could not join {room}")
        elif cmd == "FAIL" and asked:
            done_at = time.time()

    irc.send("QUIT :read-only probe done")


# --------------------------------------------------------------------- store

def ask(prompt: str, secret: bool) -> str:
    """One answer from the person running this.

    At a terminal, from the terminal (echo off for a secret). With none —
    Claude Code's `!` prompt, a launcher — from a desktop dialog, whose answer
    comes back on a pipe to this process and nowhere else.
    """
    if sys.stdin.isatty():
        return getpass.getpass(prompt) if secret else input(prompt)
    kind = ["--password"] if secret else ["--entry", "--text", prompt]
    try:
        out = subprocess.run(["zenity", *kind, "--title", "frq: " + prompt.rstrip(": ")],
                             capture_output=True, text=True, check=False)
    except FileNotFoundError:
        sys.exit("no terminal and no zenity to ask with; run this in a terminal")
    if out.returncode != 0:
        sys.exit("cancelled")
    return out.stdout.rstrip("\n")


def store(handle: str | None) -> None:
    handle = (handle or ask("handle: ", secret=False)).strip().lstrip("@")
    password = ask("app password (xxxx-xxxx-xxxx-xxxx): ", secret=True).strip()
    if not APP_PASSWORD.fullmatch(password):
        sys.exit("that is not an app password; make one under "
                 "Settings -> Privacy and security -> App passwords")
    session = create_session(handle, password)
    print(f"signed in as {session['handle']} ({session['did']})")
    keystore_write("handle", "frq: freeq handle", session["handle"])
    keystore_write("app-password", f"frq: app password for {session['handle']}",
                   password)
    print("stored in the keystore (service=frq)")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    st = sub.add_parser("store", help="prompt for the app password and store it")
    st.add_argument("--handle", help="the account's handle (asked for when omitted)")
    a = sub.add_parser("around", help="print the raw lines around one msgid")
    a.add_argument("room")
    a.add_argument("msgid")
    a.add_argument("--limit", type=int, default=10)
    a.add_argument("--host", default="irc.freeq.at")
    a.add_argument("--port", type=int, default=6697)
    a.add_argument("--settle", type=float, default=4.0,
                   help="seconds to keep reading after asking for history")
    args = parser.parse_args()
    if args.cmd == "store":
        store(args.handle)
    else:
        around(args.room, args.msgid, args.limit, args.host, args.port,
               args.settle)


if __name__ == "__main__":
    main()
