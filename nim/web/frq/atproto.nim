## Resolving an identity, in a browser.
##
## Not here, and that is the honest answer rather than a missing one. Every
## call in the desktop's half is a blocking HTTPS round trip, and `fetch` is
## asynchronous: a browser cannot be asked these questions and answer them on
## the same line.
##
## The web build therefore signs in one way, through the broker, which is the
## one flow where the answers arrive as a redirect rather than as a return
## value. An app password wants `createSession` against the reader's own PDS,
## which is exactly the shape that does not fit — and is why the connect
## screen's third tab is not offered here.
##
## `atprotocore` is what remains, and is what the handshake actually needs:
## what a session is, and the SASL payload built from one.

import std/json
import frq/atprotocore
export atprotocore

type NotOnTheWeb = object of CatchableError

proc resolveHandle*(handle: string): string =
  raise newException(NotOnTheWeb, "Handles are resolved by the broker here.")

proc pdsFor*(did: string): string =
  raise newException(NotOnTheWeb, "PDS lookup is not available in the browser.")

proc getProfile*(actor: string): JsonNode =
  raise newException(NotOnTheWeb, "Profiles are fetched by the host here.")

proc createSession*(handle, password: string): Session =
  raise newException(NotOnTheWeb,
    "An app password needs a call to your PDS, which a page cannot make. " &
    "Sign in with Bluesky instead.")
