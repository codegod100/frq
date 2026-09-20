## CAP negotiation and the SASL payload. No network: every case here is a
## line in and lines out.

import std/[json, sets, strutils, unittest]
import frq/[ircparse, atproto, handshake]

proc caps0(): HashSet[string] = initHashSet[string]()

proc guest(): Session = Session(kind: skNone)
proc signedIn(): Session =
  Session(kind: skPdsSession, did: "did:plc:abc", accessJwt: "jwt-123",
          pds: "https://pds.example")

suite "base64url":
  test "unpadded, and URL-safe":
    check b64url("hello") == "aGVsbG8"
    check '=' notin b64url("any")
    check '+' notin b64url("\xfb\xff")
    check '/' notin b64url("\xfb\xff")

  test "round-trips":
    for s in ["", "a", "ab", "abc", "{\"nonce\":\"x\"}", "😀"]:
      check b64urlDecode(b64url(s)) == s

  test "garbage decodes to nothing rather than throwing":
    check b64urlDecode("!!!not base64!!!") == ""

suite "nonceOf":
  test "the nonce out of a challenge":
    let challenge = b64url($(%*{"session_id": "s", "nonce": "N123"}))
    check nonceOf(challenge) == "N123"
  test "a challenge with no nonce":
    check nonceOf(b64url($(%*{"session_id": "s"}))) == ""
  test "a challenge that is not JSON":
    check nonceOf(b64url("not json")) == ""

suite "saslResponse":
  test "a pds-session carries the DID, the token, the PDS and the nonce":
    let payload = parseJson(b64urlDecode(saslResponse(signedIn(), "N1")))
    check payload["method"].getStr() == "pds-session"
    check payload["did"].getStr() == "did:plc:abc"
    check payload["signature"].getStr() == "jwt-123"
    check payload["pds_url"].getStr() == "https://pds.example"
    # Echoed back so the token cannot be replayed at another server.
    check payload["challenge_nonce"].getStr() == "N1"

  test "a web-token carries only the token, with the DID left empty":
    # The server looks the DID up in its own store; guessing it would be
    # wrong more often than not.
    let s = Session(kind: skWebToken, token: "tok")
    let payload = parseJson(b64urlDecode(saslResponse(s, "N1")))
    check payload["method"].getStr() == "web-token"
    check payload["signature"].getStr() == "tok"
    check payload["did"].getStr() == ""

  test "a pds-oauth carries the proof freeq will present for us":
    # freeq cannot simply hand a DPoP token to the PDS: the token is bound to
    # a key and the holder has to prove it. So the proof travels with the
    # token, minted for the exact call freeq is about to make.
    var s = signedIn()
    s.kind = skPdsOauth
    s.dpopProof = "eyJhbGciOiJFUzI1NiJ9.proof"
    let payload = parseJson(b64urlDecode(saslResponse(s, "N1")))
    check payload["method"].getStr() == "pds-oauth"
    check payload["did"].getStr() == "did:plc:abc"
    check payload["signature"].getStr() == "jwt-123"
    check payload["pds_url"].getStr() == "https://pds.example"
    check payload["dpop_proof"].getStr() == "eyJhbGciOiJFUzI1NiJ9.proof"
    check payload["challenge_nonce"].getStr() == "N1"

suite "saslLines":
  test "a short payload is one line":
    check saslLines("abc") == @["AUTHENTICATE abc"]

  test "one that lands exactly on the boundary gets a bare + after it":
    # Or the server waits for a continuation that is not coming.
    let exact = "x".repeat(saslChunk)
    let got = saslLines(exact)
    check got.len == 2
    check got[1] == "AUTHENTICATE +"

  test "a longer one is split":
    check saslLines("x".repeat(saslChunk + 5)).len == 2

suite "step: CAP":
  test "LS asks for what it can use":
    let m = parseLine(":s CAP * LS :message-tags server-time account-tag echo-message")
    let got = step(guest(), caps0(), m)
    check got.send.len == 1
    check got.send[0].startsWith("CAP REQ :")
    for c in ["message-tags", "server-time", "account-tag", "echo-message"]:
      check c in got.send[0]

  test "it asks only for what was offered":
    let m = parseLine(":s CAP * LS :server-time")
    check step(guest(), caps0(), m).send[0] == "CAP REQ :server-time"

  test "nothing on offer ends CAP rather than requesting nothing":
    check step(guest(), caps0(), parseLine(":s CAP * LS :")).send == @["CAP END"]

  test "a guest does not ask for sasl even when it is offered":
    # It would have nothing to answer the challenge with.
    let m = parseLine(":s CAP * LS :sasl server-time")
    check "sasl" notin step(guest(), caps0(), m).send[0]

  test "a signed-in session does":
    let m = parseLine(":s CAP * LS :sasl server-time")
    check "sasl" in step(signedIn(), caps0(), m).send[0]

  test "ACK with sasl starts the exchange":
    let m = parseLine(":s CAP nick ACK :sasl server-time")
    let got = step(signedIn(), caps0(), m)
    check got.send == @["AUTHENTICATE ATPROTO-CHALLENGE"]
    check "sasl" in got.caps
    check "server-time" in got.caps

  test "ACK without sasl ends CAP":
    let m = parseLine(":s CAP nick ACK :server-time")
    check step(guest(), caps0(), m).send == @["CAP END"]

  test "NAK ends CAP rather than hanging":
    check step(guest(), caps0(), parseLine(":s CAP nick NAK :sasl")).send ==
      @["CAP END"]

suite "step: AUTHENTICATE":
  test "a challenge is answered with the payload":
    let challenge = b64url($(%*{"nonce": "N9"}))
    let got = step(signedIn(), caps0(), parseLine("AUTHENTICATE " & challenge))
    check got.send.len == 1
    let payload = parseJson(b64urlDecode(got.send[0]["AUTHENTICATE ".len .. ^1]))
    check payload["challenge_nonce"].getStr() == "N9"

  test "a bare + is not a challenge":
    check step(signedIn(), caps0(), parseLine("AUTHENTICATE +")).send.len == 0

suite "step: the outcome":
  test "903 ends CAP so registration can proceed":
    check step(signedIn(), caps0(), parseLine(":s 903 n :ok")).send == @["CAP END"]

  test "904 ends CAP too rather than leaving the client hanging":
    # Refused is an outcome; the caller reports it and carries on as a guest.
    for code in ["904", "905", "906"]:
      check step(signedIn(), caps0(), parseLine(":s " & code & " n :no")).send ==
        @["CAP END"]

suite "dpopNonce":
  test "the relayed nonce":
    check dpopNonce(parseLine(":s NOTICE n :DPOP_NONCE abc123")) == "abc123"
  test "an ordinary notice is not one":
    check dpopNonce(parseLine(":s NOTICE n :hello")) == ""
  test "nor is anything else":
    check dpopNonce(parseLine(":s PRIVMSG #c :DPOP_NONCE x")) == ""
