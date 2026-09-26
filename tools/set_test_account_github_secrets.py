#!/usr/bin/env python3
"""Set the test account's Bluesky handle and app password as Actions secrets.

Tests that need a signed-in account read them as FRQ_TEST_HANDLE and
FRQ_TEST_APP_PASSWORD.  The app password is read from the terminal with echo
disabled; nothing is read from or written to environment variables, saved to
disk, or put in a command-line argument.

Before anything is stored the script signs in once, the way the app does
(handle -> DID -> PDS -> com.atproto.server.createSession), so a typo fails
here rather than in CI.  Pass --no-verify to skip that.

Only an app password is accepted, never the account's main password: CI logs
and forks are not a place for a credential that can change the account.

Prerequisite: authenticate the GitHub CLI for the account that administers the
target repository (for example, run ``gh auth login`` beforehand).
"""

from __future__ import annotations

import argparse
import getpass
import json
import re
import urllib.error
import urllib.parse
import urllib.request

from set_modal_github_secrets import require_gh_auth, set_secret

HANDLE_SECRET = "FRQ_TEST_HANDLE"
PASSWORD_SECRET = "FRQ_TEST_APP_PASSWORD"

# What bsky.app hands out under Settings -> App Passwords.
APP_PASSWORD = re.compile(r"[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}")
DIRECTORY = "https://public.api.bsky.app"
PLC = "https://plc.directory"
TIMEOUT = 15


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo",
        required=True,
        metavar="OWNER/REPOSITORY",
        help="GitHub repository that owns the Actions secrets",
    )
    parser.add_argument(
        "--handle",
        help="the test account's handle (prompted for when omitted)",
    )
    parser.add_argument(
        "--no-verify",
        action="store_true",
        help="store the secrets without signing in to the PDS first",
    )
    return parser.parse_args()


def fetch_json(url: str, body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode()
    request = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        # The PDS puts the reason in the body; a wrong password is a 401 whose
        # message is the useful part.
        try:
            message = json.load(error).get("message", "")
        except ValueError:
            message = ""
        raise RuntimeError(f"{url.split('?')[0]}: {message or error}") from None
    except urllib.error.URLError as error:
        raise RuntimeError(f"{url.split('?')[0]}: {error.reason}") from None


def pds_for(did: str) -> str:
    if did.startswith("did:plc:"):
        doc = fetch_json(f"{PLC}/{did}")
    elif did.startswith("did:web:"):
        doc = fetch_json(f"https://{did.removeprefix('did:web:')}/.well-known/did.json")
    else:
        raise RuntimeError(f"Unsupported DID method: {did}")
    for service in doc.get("service", []):
        if service.get("id", "").endswith("#atproto_pds"):
            return service["serviceEndpoint"].rstrip("/")
    raise RuntimeError(f"{did} names no PDS.")


def verify(handle: str, password: str) -> str:
    query = urllib.parse.urlencode({"handle": handle})
    did = fetch_json(f"{DIRECTORY}/xrpc/com.atproto.identity.resolveHandle?{query}")["did"]
    pds = pds_for(did)
    session = fetch_json(
        f"{pds}/xrpc/com.atproto.server.createSession",
        {"identifier": handle, "password": password},
    )
    if not session.get("accessJwt"):
        raise RuntimeError(f"{pds} returned no session.")
    return f"{session.get('handle', handle)} ({did}) at {pds}"


def main() -> int:
    args = parse_args()
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo) is None:
        raise RuntimeError("--repo must have the form OWNER/REPOSITORY.")
    require_gh_auth()

    handle = (args.handle or input("Test account handle: ")).strip().removeprefix("@")
    if not handle:
        raise RuntimeError("The handle cannot be empty.")

    print("Make an app password at bsky.app -> Settings -> App Passwords. Input is hidden.")
    password = getpass.getpass(f"{PASSWORD_SECRET}: ").strip()
    if APP_PASSWORD.fullmatch(password) is None:
        raise RuntimeError(
            "That is not an app password (xxxx-xxxx-xxxx-xxxx). "
            "Never store the account's main password as a CI secret."
        )

    if not args.no_verify:
        print(f"Signed in as {verify(handle, password)}.")

    set_secret(args.repo, HANDLE_SECRET, handle)
    set_secret(args.repo, PASSWORD_SECRET, password)
    print(f"{HANDLE_SECRET} and {PASSWORD_SECRET} are set for {args.repo}.")
    return 0


if __name__ == "__main__":
    import sys

    try:
        raise SystemExit(main())
    except (KeyboardInterrupt, EOFError):
        print("\nOperation interrupted; check GitHub for any partial update.", file=sys.stderr)
        raise SystemExit(130) from None
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
