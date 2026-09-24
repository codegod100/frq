#!/usr/bin/env python3
"""Set the Modal credentials used by the GitHub Actions deploy workflow.

The script reads every secret from the terminal with echo disabled.  It does
not read or set environment variables, save credentials, or put secret values
in command-line arguments.

Prerequisite: authenticate the GitHub CLI for the account that administers the
target repository (for example, run ``gh auth login`` beforehand).
"""

from __future__ import annotations

import argparse
import getpass
import re
import shutil
import subprocess
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repo",
        required=True,
        metavar="OWNER/REPOSITORY",
        help="GitHub repository that owns the Actions secrets",
    )
    return parser.parse_args()


def require_gh_auth() -> None:
    if shutil.which("gh") is None:
        raise RuntimeError("GitHub CLI (gh) is required but was not found on PATH.")

    result = subprocess.run(
        ["gh", "auth", "status", "--hostname", "github.com"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(
            "GitHub CLI is not authenticated for github.com. Run `gh auth login` first."
        )


def read_secret(name: str) -> str:
    value = getpass.getpass(f"{name}: ")
    if not value:
        raise RuntimeError(f"{name} cannot be empty.")
    return value


def set_secret(repo: str, name: str, value: str) -> None:
    result = subprocess.run(
        ["gh", "secret", "set", name, "--repo", repo],
        input=f"{value}\n",
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"Could not set {name}: {detail}")


def main() -> int:
    args = parse_args()
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repo) is None:
        raise RuntimeError("--repo must have the form OWNER/REPOSITORY.")
    require_gh_auth()

    print("Paste the values produced by `modal token new`. Input is hidden.")
    token_id = read_secret("MODAL_TOKEN_ID")
    token_secret = read_secret("MODAL_TOKEN_SECRET")

    set_secret(args.repo, "MODAL_TOKEN_ID", token_id)
    set_secret(args.repo, "MODAL_TOKEN_SECRET", token_secret)
    print(f"Modal Actions secrets are set for {args.repo}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (KeyboardInterrupt, EOFError):
        print("\nOperation interrupted; check GitHub for any partial update.", file=sys.stderr)
        raise SystemExit(130) from None
    except RuntimeError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(1) from None
