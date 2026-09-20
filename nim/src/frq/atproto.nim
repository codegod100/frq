## Resolving an identity, over HTTPS.
##
## The half that talks: a handle to a DID, a DID to its PDS, an app-password
## sign-in, and a profile. `atprotocore` holds what a session *is* and the
## SASL payload built from it, which is the same everywhere and is what the
## handshake needs.

import std/[httpclient, json, net, strutils]
import frq/[trace, eintr]
import frq/atprotocore
export atprotocore

proc newClient(): HttpClient =
  ## No socket timeout, and that is not an oversight: Linux never restarts a
  ## socket call that has one, whatever `SA_RESTART` says, so a timeout here
  ## means every request dies on the first signal to arrive. See `frq/eintr`.
  ## The cost is that a server which accepts and then says nothing holds the
  ## call until TCP gives up.
  newHttpClient(sslContext = newContext(verifyMode = CVerifyPeer))

proc getJson(url, whatFor: string): JsonNode =
  ## `whatFor` is what the caller was trying to do, because the failure the
  ## reader sees should be about their handle rather than about HTTP. The
  ## directory answers an unknown handle with a bare 400, and "400 Bad
  ## Request" on the connect screen tells nobody anything.
  trace("atproto", "GET " & url)
  var c: HttpClient
  try:
    var body: string
    # A client per attempt: one whose handshake a signal cut short is not one
    # to ask again. `getContent` reads the whole body, so unlike `request`
    # there is nothing left outside the retry. See `frq/eintr`.
    retrying 3:
      if c != nil:
        try: c.close() except CatchableError: discard
      c = newClient()
      body = c.getContent(url)
    parseJson(body)
  except JsonParsingError:
    raise newException(AtprotoError, whatFor & " — the server's answer was not JSON.")
  except CatchableError as e:
    trace("atproto", "!! " & e.msg)
    raise newException(AtprotoError, whatFor)
  finally:
    if c != nil:
      try: c.close() except CatchableError: discard

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

  var c: HttpClient
  try:
    let payload = $(%*{"identifier": handle.strip(), "password": password})
    var status, raw: string
    retrying 3:
      if c != nil:
        try: c.close() except CatchableError: discard
      c = newClient()
      c.headers = newHttpHeaders({"Content-Type": "application/json"})
      let res = c.request("https://" & hostOf(pds) &
                          "/xrpc/com.atproto.server.createSession",
                          httpMethod = HttpPost, body = payload)
      # Inside the retry: `Response.body` is a stream read where it is first
      # touched, so reading it below would put the longest blocking part of
      # the round trip outside the retry meant to cover it.
      status = res.status
      raw = res.body
    # Read the body whatever the status: the PDS puts the reason in it, and a
    # wrong app password is a 401 whose message is the useful part.
    let body = try: parseJson(raw)
               except JsonParsingError:
                 raise newException(AtprotoError,
                   "Your PDS refused the sign-in (" & status & ").")
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
    if c != nil:
      try: c.close() except CatchableError: discard

