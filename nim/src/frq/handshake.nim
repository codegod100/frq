## CAP negotiation and the SASL exchange inside it, as lines to send.
##
## From `common/frq/irc/handshake.cljc`, and the shape is kept: every step is
## the same question — given what the server just said, what does this client
## say back — so it answers with lines and the caller writes them.

import std/[sets, strutils]
import frq/[ircparse, atproto, msgsig]

const
  saslChunk* = 100_000
    ## How much of a SASL payload goes on one AUTHENTICATE line.
    ##
    ## 400 is the IRCv3 figure and it assumes something freeq does not do:
    ## that the server reassembles continuation lines. It does not —
    ## `handle_authenticate` base64-decodes the single param it was handed, so
    ## a split payload arrives as its own first 400 characters and comes back
    ## as `904 SASL authentication failed (bad response)`. What freeq wants is
    ## the whole thing on one line, which it can afford: a custom server
    ## reading lines off a WebSocket bridge rather than a 512-byte ircd.

  wantedCaps* = ["message-tags", "server-time", "account-tag", "echo-message",
                 "freeq.at/msgsig"]
    ## What this client can use, and why even a guest negotiates.
    ##
    ## `server-time`: without it a replayed backlog arrives untimed and every
    ## old line reads as just said. `account-tag`: the sender's DID, which is
    ## the only identity a client is given — a nick is whatever someone chose
    ## today. Both need `message-tags` beside them, since IRCv3 sends tags
    ## only to clients that asked for tags at all; either alone is ACKed and
    ## then nothing arrives. `echo-message`: our own lines come back, which is
    ## the only way this client learns the msgid of something it said —
    ## without it a reaction or reply aimed at one has nothing to name.

type
  Step* = object
    send*: seq[string]
    caps*: HashSet[string]

proc saslLines*(payload: string): seq[string] =
  ## A payload split the way AUTHENTICATE wants it. One that lands exactly on
  ## the boundary is followed by a bare `+`, so the server knows it ended
  ## rather than waiting for a continuation that is not coming.
  var rest = payload
  while rest.len > saslChunk:
    result.add "AUTHENTICATE " & rest[0 ..< saslChunk]
    rest = rest[saslChunk .. ^1]
  result.add "AUTHENTICATE " & rest
  if rest.len == saslChunk:
    result.add "AUTHENTICATE +"

func dpopNonce*(m: IrcLine): string =
  ## The DPoP nonce freeq is relaying, or "".
  ##
  ## `NOTICE <target> :DPOP_NONCE <nonce>`, and it is not chatter: the server
  ## called the PDS's getSession with our proof, was answered `use_dpop_nonce`
  ## and is passing on the nonce the PDS wants. Only an OAuth session can do
  ## anything with it; the other methods carry no proof to re-mint.
  if m.command != "NOTICE" or m.params.len == 0: return ""
  let text = m.params[^1]
  if not text.startsWith("DPOP_NONCE "): return ""
  text["DPOP_NONCE ".len .. ^1].strip()

proc step*(session: Session, caps: HashSet[string], m: IrcLine): Step =
  ## What to send in answer to `m`, and what it did to the acked set.
  ##
  ## `caps` comes back whether it changed or not, so a caller can keep it in
  ## whatever it keeps state in without this module holding any.
  result.caps = caps

  case m.command
  of "CAP":
    if m.params.len < 2: return
    let sub = m.params[1]
    let offeredStr = if m.params.len >= 3: m.params[^1] else: ""
    var offered = initHashSet[string]()
    for c in offeredStr.split({' ', '\t'}):
      if c.len > 0: offered.incl c

    case sub
    of "LS":
      var wanted: seq[string]
      for c in wantedCaps:
        if c in offered: wanted.add c
      # sasl only where there is something to authenticate with. A guest asks
      # for it and then has nothing to say.
      if session.kind != skNone and "sasl" in offered: wanted.add "sasl"
      result.send = @[if wanted.len > 0: "CAP REQ :" & wanted.join(" ")
                      else: "CAP END"]
    of "ACK":
      for c in offeredStr.split({' ', '\t'}):
        if c.len > 0: result.caps.incl c
      result.send = @[if "sasl" in offeredStr: "AUTHENTICATE ATPROTO-CHALLENGE"
                      else: "CAP END"]
    of "NAK":
      result.send = @["CAP END"]
    else: discard

  of "AUTHENTICATE":
    let challenge = if m.params.len > 0: m.params[0] else: ""
    if challenge.len > 0 and challenge != "+":
      result.send = saslLines(saslResponse(session, nonceOf(challenge)))

  of "903":
    # Authenticated. Mint the signing key now, while the server is still in
    # CAP — `freeq.at/msgsig` is what makes a signed-in account able to react
    # at all, and an unsigned mutation comes back
    # `FAIL TAGMSG SIGNATURE_REQUIRED`.
    if "freeq.at/msgsig" in caps and session.did.len > 0:
      result.send = @["MSGSIG " & generate(session.did), "CAP END"]
    else:
      result.send = @["CAP END"]

  of "904", "905", "906":
    # Refused. End CAP anyway and carry on as a guest rather than hanging —
    # the caller reports what happened.
    result.send = @["CAP END"]

  else: discard
