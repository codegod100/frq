## Signing in with Bluesky, in a browser.
##
## Not through freeq's broker, and that is forced rather than chosen. The
## broker finishes a login by redirecting to `return_to`, and it only
## redirects to hosts on its own allowlist — loopback, and its own freeq
## origins. The desktop is loopback and is fine. A page served from anywhere
## else is refused before the reader sees a login form at all: `Invalid
## return_to URL`, which is what the deployed build said.
##
## So the page is its own OAuth client, which works because an authorization
## server takes the client's *own* metadata document as the authority on where
## a code may be sent — and that document is served from this origin.
##
## None of that is here. It is `flutter/web/frq_oauth.js`, because every step
## of it is asynchronous — `fetch`, and WebCrypto for the DPoP key — and this
## core is not. What this module does is what the desktop half does: say what
## is wanted, and take the answer when it comes.
##
## `oauthcore` is still shared, for the little of the broker flow that
## survives: nothing here builds a login URL any more, but `Tokens` and
## `OauthError` are the shape the reducer already knows.

import std/[deques, json, strutils]
import frq/[oauthcore, trace]
export oauthcore

const hostSignsIn* = true
  ## This host does its own OAuth; the reducer reads this to know which of
  ## the two shapes of sign-in it is looking at. The desktop's `oauth` says
  ## `false` and means the broker.

var
  events: Deque[string]   ## "ok: …" | "error: …", as the desktop's
  running: bool
  wantSignIn: string
    ## The handle the host should start a sign-in for, or "".
  wantProof: bool
    ## Whether the host should mint the proof for a connection.

proc begin*(broker, handle: string, openBrowser = true) =
  ## Ask the host to sign in. `broker` is ignored — there is no broker on this
  ## path, and the argument stays so the seam is one signature.
  ##
  ## Nothing happens here and nothing is awaited: the host leaves the page for
  ## the authorization server, and what comes back comes back as a fresh load.
  running = true
  wantSignIn = handle.strip()
  trace("oauth", "asking the host to sign in as " & wantSignIn)

proc wantedSignIn*(): string =
  ## The handle to sign in as, taken as it is read — a sign-in is started
  ## once, and a page that asked twice would leave for the authorization
  ## server twice.
  result = wantSignIn
  wantSignIn = ""

proc needProof*(): bool =
  ## Whether a connection is waiting on a DPoP proof. Taken as it is read,
  ## for the reason above.
  result = wantProof
  wantProof = false

proc askForProof*() =
  ## Before a connection: freeq presents a proof to the PDS on this client's
  ## behalf, and minting one is WebCrypto. Per connect, because a proof
  ## carries an `iat` and a single-use `jti`.
  wantProof = true

proc handoff*(payload: string) =
  ## A finished sign-in, as JSON from the host. Not the broker's base64
  ## payload — there is no broker — so this is the one place the two hosts
  ## disagree about what a handoff looks like.
  if payload.len == 0: return
  running = true
  events.addLast("ok: " & payload.strip())

proc failed*(reason: string) =
  running = true
  events.addLast("error: " & reason)

var wantForget: bool

proc forgetHostSession*() = wantForget = true
  ## The host holds the access token, the refresh token and the key they are
  ## bound to. A key outliving the token it was bound to is a key with
  ## nothing to prove, so all three go together.

proc needForget*(): bool =
  result = wantForget
  wantForget = false

proc cancel*() = running = false
proc finished*() = running = false
proc waiting*(): bool = running
proc tryEvent*(): (bool, string) =
  if events.len == 0: (false, "") else: (true, events.popFirst())

proc refreshSession*(broker, brokerToken: string): Tokens =
  ## Not here, and not needed: a browser sign-in keeps its own session and
  ## renews it through the authorization server rather than through a broker
  ## token this client never had.
  raise newException(OauthError, "there is no broker on this path")
