## handle → DID → PDS → session, and the SASL payload freeq takes.
##
## From `common/frq/atproto/core.cljc`. That file is split into `-req` and
## `-parse` pairs because ClojureDart had no portable HTTP client and the host
## had to make the call in between; Nim has `std/httpclient`, so the round
## trips are here whole and the seam is gone.
##
## The JSON is `std/json` rather than the hand-rolled string scanner the
## Clojure uses. That scanner exists because two compilers disagreed about
## JSON and neither could be depended on; one language has one JSON.

import std/[base64, httpclient, json, net, strutils]
import frq/trace

const
  directoryHost* = "public.api.bsky.app"
  plcHost* = "plc.directory"

type
  SessionKind* = enum
    skNone = "none", skPdsSession = "pds-session", skWebToken = "web-token"

  Session* = object
    kind*: SessionKind
    did*: string
    handle*: string
    accessJwt*: string
    pds*: string
    token*: string        ## a web-token from the broker, where that is the kind

  AtprotoError* = object of CatchableError

proc b64url*(s: string): string =
  ## base64url, unpadded — what AUTHENTICATE carries.
  s.encode().replace("+", "-").replace("/", "_").replace("=", "")

proc b64urlDecode*(s: string): string =
  var t = s.replace("-", "+").replace("_", "/")
  # `decode` wants the padding the wire form drops.
  while t.len mod 4 != 0: t.add '='
  try: decode(t) except CatchableError: ""

proc newClient(): HttpClient =
  newHttpClient(timeout = 15_000,
                sslContext = newContext(verifyMode = CVerifyPeer))

proc getJson(url, whatFor: string): JsonNode =
  ## `whatFor` is what the caller was trying to do, because the failure the
  ## reader sees should be about their handle rather than about HTTP. The
  ## directory answers an unknown handle with a bare 400, and "400 Bad
  ## Request" on the connect screen tells nobody anything.
  trace("atproto", "GET " & url)
  let c = newClient()
  try:
    parseJson(c.getContent(url))
  except JsonParsingError:
    raise newException(AtprotoError, whatFor & " — the server's answer was not JSON.")
  except CatchableError as e:
    trace("atproto", "!! " & e.msg)
    raise newException(AtprotoError, whatFor)
  finally:
    c.close()

func hostOf*(url: string): string =
  var u = url
  for scheme in ["https://", "http://"]:
    if u.startsWith(scheme): u = u[scheme.len .. ^1]
  let i = u.find('/')
  if i < 0: u else: u[0 ..< i]

proc resolveHandle*(handle: string): string =
  ## A handle to a DID. One that is already a DID needs no call and passes
  ## through, which is why this is not simply a request builder.
  let h = handle.strip()
  if h.startsWith("did:"): return h
  if h.len == 0: raise newException(AtprotoError, "A handle is required.")
  let doc = getJson("https://" & directoryHost &
                    "/xrpc/com.atproto.identity.resolveHandle?handle=" & h,
                    "Could not resolve handle " & h)
  let did = doc{"did"}.getStr()
  if did.len == 0:
    raise newException(AtprotoError, "Could not resolve handle " & h)
  did

proc pdsFor*(did: string): string =
  ## The PDS endpoint out of the DID document.
  ##
  ## did:plc documents come from the PLC directory; did:web ones from the
  ## domain itself, which is the whole of what did:web means.
  var doc: JsonNode
  if did.startsWith("did:plc:"):
    doc = getJson("https://" & plcHost & "/" & did,
                  "Could not read the DID document for " & did)
  elif did.startsWith("did:web:"):
    doc = getJson("https://" & did["did:web:".len .. ^1] & "/.well-known/did.json",
                  "Could not read the DID document for " & did)
  else:
    raise newException(AtprotoError, "Unsupported DID method: " & did)

  # The document lists several services; the PDS is the one whose type is
  # AtprotoPersonalDataServer.
  if doc.hasKey("service"):
    for svc in doc["service"]:
      if svc{"type"}.getStr() == "AtprotoPersonalDataServer":
        let ep = svc{"serviceEndpoint"}.getStr()
        if ep.len > 0: return ep
  raise newException(AtprotoError, "No PDS endpoint for " & did)

proc getProfile*(actor: string): JsonNode =
  ## `app.bsky.actor.getProfile` for a DID or a handle.
  ##
  ## The actor goes in unescaped, as it always has: a handle is a domain name
  ## and a DID is `did:` and base32, and neither carries a character a query
  ## string would mind.
  getJson("https://" & directoryHost &
          "/xrpc/app.bsky.actor.getProfile?actor=" & actor,
          "Could not look up " & actor)

proc createSession*(handle, password: string): Session =
  ## Sign in to the PDS with an app password.
  ##
  ## The password goes to the user's own PDS and nowhere else — freeq never
  ## sees it, and verifies the token it gets by asking that same PDS.
  let did = resolveHandle(handle)
  let pds = pdsFor(did)
  trace("atproto", "createSession at " & pds)

  let c = newClient()
  try:
    c.headers = newHttpHeaders({"Content-Type": "application/json"})
    let payload = $(%*{"identifier": handle.strip(), "password": password})
    let res = c.request("https://" & hostOf(pds) &
                        "/xrpc/com.atproto.server.createSession",
                        httpMethod = HttpPost, body = payload)
    # Read the body whatever the status: the PDS puts the reason in it, and a
    # wrong app password is a 401 whose message is the useful part.
    let body = try: parseJson(res.body)
               except JsonParsingError:
                 raise newException(AtprotoError,
                   "Your PDS refused the sign-in (" & res.status & ").")
    let jwt = body{"accessJwt"}.getStr()
    if jwt.len == 0:
      let msg = body{"message"}.getStr()
      raise newException(AtprotoError,
                         if msg.len > 0: msg else: "Sign-in failed")
    Session(kind: skPdsSession,
            did: (if body{"did"}.getStr().len > 0: body{"did"}.getStr() else: did),
            handle: (if body{"handle"}.getStr().len > 0: body{"handle"}.getStr()
                     else: handle),
            accessJwt: jwt,
            pds: pds)
  finally:
    c.close()

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
