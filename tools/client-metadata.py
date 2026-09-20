#!/usr/bin/env python3
"""The OAuth client metadata document, for one origin.

An authorization server fetches this from the URL in `client_id` and takes
*this document* as the authority on where a code may be sent. That is the
whole reason the browser build can sign in at all: freeq's broker only
redirects to its own allowlist, and this list is ours.

Generated rather than committed because every value in it is absolute. The
`client_id` has to equal the URL this is served from, and `redirect_uris` has
to contain the page the reader comes back to — so a file with one origin
baked in is a file that is wrong everywhere else.

    tools/client-metadata.py https://example.test > client-metadata.json
"""

import json
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: client-metadata.py <origin>   # e.g. https://x.test")

origin = sys.argv[1].rstrip("/")

print(json.dumps({
    "client_id": f"{origin}/client-metadata.json",
    "client_name": "frq",
    "client_uri": f"{origin}/",
    "redirect_uris": [f"{origin}/"],
    "grant_types": ["authorization_code", "refresh_token"],
    "response_types": ["code"],
    # `atproto` is the identity scope freeq needs; `transition:generic` is
    # what a PDS still wants for ordinary reads and writes.
    "scope": "atproto transition:generic",
    # No secret. A page cannot keep one, and does not need to: what stands in
    # for it is DPoP, below — every token is bound to a key this client
    # proves it holds.
    "token_endpoint_auth_method": "none",
    "application_type": "web",
    "dpop_bound_access_tokens": True,
}, indent=2))
