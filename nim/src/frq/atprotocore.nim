## What an AT Protocol identity is, and what freeq is told about it.
##
## The pure half: the session an identity becomes, the SASL payload built
## from it, and the base64url both ends agree on. `atproto` itself does the
## HTTP, and is the half a browser replaces — `fetch` is asynchronous where
## this is not, so on the web the host resolves an identity and hands the
## answer in rather than being called into.

import std/[base64, json, strutils]

const
  directoryHost* = "public.api.bsky.app"
  plcHost* = "plc.directory"

type
  SessionKind* = enum
    skNone = "none", skPdsSession = "pds-session", skWebToken = "web-token",
    skPdsOauth = "pds-oauth"

  Session* = object
    kind*: SessionKind
    did*: string
    handle*: string
    accessJwt*: string
    pds*: string
    token*: string        ## a web-token from the broker, where that is the kind
    dpopProof*: string
      ## The proof freeq presents to the PDS on this client's behalf, for
      ## `pds-oauth`. Minted by the host rather than here: it is WebCrypto in
      ## a browser and this module does no I/O — and it is minted per connect,
      ## because a proof carries an `iat` and a single-use `jti`, so one kept
      ## from sign-in would be refused by the time a reconnect offered it.
    dpopNonce*: string
      ## The nonce the PDS last asked for, carried into the next proof so the
      ## first authenticated call does not cost a round trip to be told.

  AtprotoError* = object of CatchableError

proc b64url*(s: string): string =
  ## base64url, unpadded — what AUTHENTICATE carries.
  s.encode().replace("+", "-").replace("/", "_").replace("=", "")

proc b64urlDecode*(s: string): string =
  var t = s.replace("-", "+").replace("_", "/")
  # `decode` wants the padding the wire form drops.
  while t.len mod 4 != 0: t.add '='
  try: decode(t) except CatchableError: ""

func hostOf*(url: string): string =
  var u = url
  for scheme in ["https://", "http://"]:
    if u.startsWith(scheme): u = u[scheme.len .. ^1]
  let i = u.find('/')
  if i < 0: u else: u[0 ..< i]

proc saslResponse*(s: Session, nonce: string): string =
  ## The base64url SASL payload, for either kind freeq takes.
  ##
  ## A pds-session carries the PDS token, the DID it belongs to, its PDS, and
  ## the server's own nonce echoed back so the token cannot be replayed at
  ## another server. A web-token from the broker carries only the token — the
  ## server looks the DID up in its own store, which is why the field is sent
  ## empty rather than guessed at.
  case s.kind
  of skWebToken:
    b64url($(%*{"did": "", "method": "web-token", "signature": s.token}))
  of skPdsOauth:
    # An OAuth access token, which the server cannot simply present to the
    # PDS: a DPoP token is bound to a key, and the holder has to prove it. So
    # the proof travels with it. freeq calls getSession with our token and our
    # proof, and the PDS checks that the proof names that method, that URL and
    # that token — which is what lets a proof be minted for a request this
    # client never makes.
    b64url($(%*{"did": s.did,
                "signature": s.accessJwt,
                "method": "pds-oauth",
                "pds_url": s.pds,
                "dpop_proof": s.dpopProof,
                "challenge_nonce": nonce}))
  else:
    b64url($(%*{"did": s.did,
                "signature": s.accessJwt,
                "method": "pds-session",
                "pds_url": s.pds,
                "challenge_nonce": nonce}))

proc nonceOf*(challenge: string): string =
  ## The nonce out of the server's AUTHENTICATE challenge, which is a
  ## base64url JSON object.
  let raw = b64urlDecode(challenge)
  if raw.len == 0: return ""
  try: parseJson(raw){"nonce"}.getStr() except CatchableError: ""
