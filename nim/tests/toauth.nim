## The broker flow, minus the browser: a URL in, a payload out.
##
## No network and no socket here. What is worth testing about this module is
## the encoding either end has to agree on — a handle in a query string, a
## base64url payload, a Content-Length header — and all of it is a string in
## and a string out.

import std/[base64, httpclient, json, os, strutils, unittest]
import frq/oauth

suite "urlEncode":
  test "the unreserved set goes through untouched":
    check urlEncode("alice.bsky.social") == "alice.bsky.social"
    check urlEncode("a-z_0.9~") == "a-z_0.9~"
  test "everything else is percent-encoded, in upper-case hex":
    check urlEncode("a b") == "a%20b"
    check urlEncode("a/b?c=d&e") == "a%2Fb%3Fc%3Dd%26e"
    check urlEncode("@alice") == "%40alice"
  test "a non-ASCII handle is encoded per byte, not per character":
    # é is two bytes in UTF-8, and a percent-encoder that passes it through
    # has not encoded anything.
    check urlEncode("café") == "caf%C3%A9"

suite "loginUrl":
  test "handle and return_to are both encoded":
    check loginUrl("https://auth.freeq.at", "alice.bsky.social",
                   "http://127.0.0.1:7391") ==
      "https://auth.freeq.at/auth/login?handle=alice.bsky.social" &
      "&return_to=http%3A%2F%2F127.0.0.1%3A7391"
  test "a trailing slash on the broker is not doubled":
    check loginUrl("https://auth.freeq.at/", "a.uk", "x").startsWith(
      "https://auth.freeq.at/auth/login?")
  test "an empty broker is the default one":
    check loginUrl("", "a.uk", "x").startsWith(defaultBroker & "/auth/login?")
  test "a leading @ is how it is written beside a message, not part of it":
    check "handle=alice.uk&" in loginUrl("", "@alice.uk", "x")
  test "and so is the whitespace around a pasted handle":
    check "handle=alice.uk&" in loginUrl("", "  alice.uk ", "x")

suite "brokerHost":
  test "the host alone, whatever the scheme":
    check brokerHost("https://auth.freeq.at") == "auth.freeq.at"
    check brokerHost("http://localhost:8080/x") == "localhost:8080"
    check brokerHost("") == "auth.freeq.at"

proc payload(j: JsonNode): string =
  ## What the broker puts in the fragment: base64url, unpadded.
  encode($j).replace("+", "-").replace("/", "_").replace("=", "")

suite "tokensOf":
  test "a full payload becomes fields":
    let t = tokensOf(payload(%*{"token": "web", "broker_token": "durable",
                                "nick": "alice", "did": "did:plc:a",
                                "handle": "alice.uk"}))
    check t.token == "web"
    check t.brokerToken == "durable"
    check t.nick == "alice"
    check t.did == "did:plc:a"
    check t.handle == "alice.uk"
  test "surrounding whitespace is the browser's, not the payload's":
    check tokensOf("  " & payload(%*{"token": "a", "broker_token": "b"}) &
                   "\n").token == "a"
  test "either token missing is a failure, not a half sign-in":
    expect OauthError: discard tokensOf(payload(%*{"token": "web"}))
    expect OauthError: discard tokensOf(payload(%*{"broker_token": "d"}))
  test "and the broker's own reason is what gets raised":
    try:
      discard tokensOf(payload(%*{"error": "that handle has no account"}))
      check false
    except OauthError as e:
      check e.msg == "that handle has no account"
  test "something that is not base64url JSON at all":
    expect OauthError: discard tokensOf("not-a-payload")
    expect OauthError: discard tokensOf("")

suite "contentLengthOf":
  test "the header, however the client capitalised it":
    check contentLengthOf("POST /capture\r\nContent-Length: 42\r\n\r\n") == 42
    check contentLengthOf("POST /capture\r\ncontent-length: 7\r\n\r\n") == 7
  test "no header is no body":
    check contentLengthOf("GET / HTTP/1.1\r\nHost: x\r\n\r\n") == 0
  test "and a header that is not a number does not throw":
    check contentLengthOf("POST /\r\nContent-Length: banana\r\n\r\n") == 0

suite "httpResponse":
  test "the length is the body's, in bytes":
    let r = httpResponse("200 OK", "text/plain", "héllo")
    check "Content-Length: 6" in r        # é is two bytes
    check r.startsWith("HTTP/1.1 200 OK\r\n")
    check r.endsWith("\r\n\r\nhéllo")

suite "captureHtml":
  test "posts the fragment back, because a fragment never reaches a server":
    let h = captureHtml()
    check "location.hash" in h
    check "'/capture'" in h
    check "method:'POST'" in h

suite "the loopback listener":
  # The one part of this that is not a string in and a string out. It binds a
  # port, serves the capture page, and waits — so the test is a real browser's
  # side of the handoff: fetch the page, post the fragment back, and see the
  # tokens come out of the channel.
  #
  # No browser is opened. `begin` takes that as a parameter for this test
  # alone; the URL it would have opened comes out on the channel regardless,
  # and is what these requests are aimed at.
  test "serves the page, ignores junk, and completes on a real payload":
    let good = payload(%*{"token": "web", "broker_token": "durable",
                          "nick": "alice", "did": "did:plc:a",
                          "handle": "alice.uk"})
    begin(defaultBroker, "alice.uk", openBrowser = false)
    defer: finished()

    var url: string
    for _ in 0 .. 200:
      let (ok, e) = tryEvent()
      if ok and e.startsWith("url: "): url = e[5 .. ^1]; break
      sleep(25)
    require url.len > 0

    # The `return_to` we handed the broker is the address to talk to.
    let here = url.split("return_to=")[1]
                  .replace("%3A", ":").replace("%2F", "/")
    let c = newHttpClient(timeout = 5000)
    defer: c.close()

    # A GET is the browser landing on us: it gets the page whose script posts
    # the fragment back.
    check "location.hash" in c.getContent(here)

    # A POST carrying nothing usable is not the end of the wait — the real
    # handoff may still be on its way.
    check c.request(here & "/capture", httpMethod = HttpPost,
                    body = "garbage").status.startsWith("400")
    check not tryEvent()[0]

    check c.request(here & "/capture", httpMethod = HttpPost,
                    body = good).body == "ok"
    var got: string
    for _ in 0 .. 200:
      let (ok, e) = tryEvent()
      if ok: got = e; break
      sleep(25)
    require got.startsWith("ok: ")
    check tokensOf(got[4 .. ^1]).brokerToken == "durable"
