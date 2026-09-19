## Signing in with Bluesky, through freeq's auth broker.
##
## From `common/frq/oauth/core.cljc` and `flutter/src/frq/oauth/dart.cljd`,
## which were two files because ClojureDart compiled for a browser as well:
## building the URL and reading the payload were portable, catching the
## redirect was not. Nim only has the desktop, so it is one file.
##
## The broker at `auth.freeq.at` does the AT Protocol OAuth with the reader's
## own PDS — the app never sees a password and never holds a DPoP key. All a
## client does is send them there and read what comes back:
##
##   1. bind a loopback listener on a port the kernel picks
##   2. open `<broker>/auth/login?handle=…&return_to=http://127.0.0.1:<port>`
##   3. the browser lands back on us with the payload in the URL *fragment*
##   4. a fragment never reaches a server, so the page we serve posts it back
##   5. that payload carries a single-use web-token and a durable broker token
##
## The web-token goes straight into SASL and is spent; the broker token is
## what `refreshSession` trades for a new one on the next run, and the only
## thing worth writing to disk.
##
## The wait is a thread, like `conn`'s, and for the same reason: a reader
## takes as long as they take over a login page, and `dispatch` is called on
## the frame.

import std/[base64, httpclient, json, nativesockets, net, osproc,
            strutils, times]
import frq/trace

const
  defaultBroker* = "https://auth.freeq.at"
  loginTimeout = 5 * 60   ## seconds; a login page nobody finishes

type
  Tokens* = object
    ## What the broker hands back. `token` is single-use.
    token*, brokerToken*, nick*, did*, handle*: string

  OauthError* = object of CatchableError

# ----------------------------------------------------------------- the url

const hexDigits = "0123456789ABCDEF"

func unreserved(b: byte): bool =
  ## RFC 3986's unreserved set, by byte value: A-Z a-z 0-9 - _ . ~
  ##
  ## By number rather than by `isAlphaNumeric`, which would also say yes to
  ## é — and a percent-encoder that passes é through has not encoded
  ## anything.
  (b >= 48'u8 and b <= 57'u8) or (b >= 65'u8 and b <= 90'u8) or
  (b >= 97'u8 and b <= 122'u8) or b in [45'u8, 95'u8, 46'u8, 126'u8]

func urlEncode*(s: string): string =
  ## Percent-encode everything a handle could hold that a query string cannot.
  ##
  ## Over UTF-8 bytes rather than characters: a non-ASCII handle is several
  ## bytes and each is encoded on its own, which is what the spec says and
  ## what the broker expects.
  for c in s:
    let b = byte(c)
    if unreserved(b): result.add c
    else:
      result.add '%'
      result.add hexDigits[int(b shr 4)]
      result.add hexDigits[int(b and 0x0f)]

func trimmedBroker(broker: string): string =
  result = if broker.len > 0: broker else: defaultBroker
  while result.len > 0 and result[^1] == '/': result.setLen(result.len - 1)

func loginUrl*(broker, handle, returnTo: string): string =
  ## Where the browser goes. A leading `@` on the handle is the reader typing
  ## it the way it appears beside a message, not part of it.
  var h = handle.strip()
  if h.startsWith("@"): h = h[1 .. ^1]
  trimmedBroker(broker) & "/auth/login?handle=" & urlEncode(h) &
    "&return_to=" & urlEncode(returnTo)

func brokerHost*(broker: string): string =
  var b = trimmedBroker(broker)
  if b.startsWith("https://"): b = b[8 .. ^1]
  elif b.startsWith("http://"): b = b[7 .. ^1]
  b.split('/')[0]

# ------------------------------------------------------------- the handoff

proc b64urlDecode(s: string): string =
  var t = s.replace("-", "+").replace("_", "/")
  while t.len mod 4 != 0: t.add '='
  try: decode(t) except CatchableError: ""

proc tokensOf*(payload: string): Tokens =
  ## The broker's base64url JSON payload, as fields.
  ##
  ## Both tokens or none: a payload missing either is the broker reporting a
  ## failure, and it puts the reason in `error`.
  let raw = b64urlDecode(payload.strip())
  let j = try: parseJson(raw)
          except CatchableError:
            raise newException(OauthError, "Malformed sign-in payload")
  result = Tokens(token: j{"token"}.getStr(),
                  brokerToken: j{"broker_token"}.getStr(),
                  nick: j{"nick"}.getStr(),
                  did: j{"did"}.getStr(),
                  handle: j{"handle"}.getStr())
  if result.token.len == 0 or result.brokerToken.len == 0:
    let e = j{"error"}.getStr()
    raise newException(OauthError,
                       if e.len > 0: e else: "Malformed sign-in payload")

proc refreshSession*(broker, brokerToken: string): Tokens =
  ## Mint a fresh web-token from the durable broker token.
  ##
  ## This is what a second run uses: the token that came back through the
  ## browser was spent on the first connection, and the reader should not see
  ## a login page again for it.
  let c = newHttpClient(timeout = 15_000,
                        sslContext = newContext(verifyMode = CVerifyPeer))
  try:
    c.headers = newHttpHeaders({"Content-Type": "application/json"})
    let res = c.request("https://" & brokerHost(broker) & "/session",
                        httpMethod = HttpPost,
                        body = $(%*{"broker_token": brokerToken}))
    # The body whatever the status: an expired token is a 401 whose message
    # is the part worth showing.
    let j = try: parseJson(res.body)
            except CatchableError:
              raise newException(OauthError,
                "The broker's answer was not JSON (" & res.status & ").")
    let token = j{"token"}.getStr()
    if token.len == 0:
      let m = j{"message"}.getStr()
      raise newException(OauthError,
        if m.len > 0: m else: "Broker session refresh failed — sign in again")
    Tokens(token: token, brokerToken: brokerToken,
           nick: j{"nick"}.getStr(), did: j{"did"}.getStr(),
           handle: j{"handle"}.getStr())
  finally:
    c.close()

# --------------------------------------------------------- the capture page

func captureHtml*(): string =
  ## The page the browser lands on, whose one job is to post the fragment
  ## back — a fragment never reaches a server, so nothing here can read it
  ## without a line of script.
  ##
  ## The Clojure took a `return-url` for Android, where the browser is in
  ## front of the app and a `frq://` link has to raise it. On a desktop the
  ## window is already beside the browser, so the page says the reader can
  ## close the tab and that is the whole of it.
  "<!doctype html><meta charset=utf-8><title>frq</title>" &
  "<body style=\"font:15px system-ui;background:#242424;color:#fff;padding:40px\">" &
  "<p id=m>Finishing sign-in…</p>" &
  "<script>" &
  "var h=location.hash.replace(/^#/,'');" &
  "var p=new URLSearchParams(h).get('oauth')||h.replace(/^oauth=/,'');" &
  "if(!p){document.getElementById('m').textContent='No sign-in payload in this URL.';}" &
  "else{fetch('/capture',{method:'POST',body:p})" &
  ".then(function(){document.getElementById('m').textContent=" &
  "'Signed in — you can close this tab.';})" &
  ".catch(function(e){document.getElementById('m').textContent='Handoff failed: '+e;});}" &
  "</script></body>"

func httpResponse*(status, contentType, body: string): string =
  ## One response, headers and all. Hand-written rather than
  ## `asynchttpserver`, because this server answers two shapes of request on
  ## a socket nothing outside this machine can reach, and async in a thread
  ## buys nothing for it.
  "HTTP/1.1 " & status & "\r\n" &
  "Content-Type: " & contentType & "\r\n" &
  "Content-Length: " & $body.len & "\r\n" &
  "Connection: close\r\n" &
  "Cache-Control: no-store\r\n\r\n" & body

func contentLengthOf*(head: string): int =
  ## The body length out of a request's headers, or 0 where it says none.
  ##
  ## Case-insensitively: the header is whatever the browser felt like
  ## capitalising, and `fetch` sends `content-length` in lower case where
  ## curl sends it capitalised.
  for line in head.splitLines():
    let colon = line.find(':')
    if colon > 0 and line[0 ..< colon].strip().toLowerAscii() == "content-length":
      return try: parseInt(line[colon + 1 .. ^1].strip()) except ValueError: 0
  0

# ------------------------------------------------------------- the listener

type LoginReq = object
  broker, handle: string
  openBrowser: bool

var
  events: Channel[string]   ## "url: <login url>" | "ok: <payload>" | "error: …"
  worker: Thread[LoginReq]
  running: bool
  cancelled: bool

proc openInBrowser(url: string) =
  ## Best effort. The URL is on the screen either way — `loginUrl` is shown
  ## under "If the browser did not open, visit:" for exactly the machine
  ## where this does nothing.
  try:
    let p = startProcess("xdg-open", args = [url], options = {poUsePath})
    p.close()
  except CatchableError as e:
    trace("oauth", "could not open a browser: " & e.msg)

proc readRequest(client: Socket): (string, string) =
  ## A request as (head, body). Read by hand: the head ends at a blank line,
  ## and the body is exactly what Content-Length says — a fragment posted
  ## back is one short line and never chunked.
  var head: string
  while not head.endsWith("\r\n\r\n"):
    var c: string
    if client.recv(c, 1, timeout = 10_000) <= 0: return ("", "")
    head.add c
    if head.len > 16_384: return ("", "")   # nothing legitimate is this big
  let want = contentLengthOf(head)
  var body: string
  if want > 0 and want <= 16_384:
    discard client.recv(body, want, timeout = 10_000)
  (head, body)

proc workerBody(req: LoginReq) {.thread.} =
  var server = newSocket()
  try:
    server.setSockOpt(OptReuseAddr, true)
    server.bindAddr(Port(0), "127.0.0.1")
    server.listen()
    let port = server.getLocalAddr()[1]
    let url = loginUrl(req.broker, req.handle,
                       "http://127.0.0.1:" & $uint16(port))
    trace("oauth", "listening on " & $uint16(port))
    events.send("url: " & url)
    if req.openBrowser: openInBrowser(url)

    let deadline = epochTime() + loginTimeout.float
    while not cancelled and epochTime() < deadline:
      # A second at a time rather than a blocking accept, so cancelling and
      # the deadline are both answered without another thread closing a
      # socket this one is sitting inside.
      var readable = @[server.getFd()]
      if selectRead(readable, 1000) <= 0: continue

      var client: Socket
      try:
        server.accept(client)
        let (head, body) = readRequest(client)
        if head.startsWith("POST"):
          # A POST carrying nothing usable is not the end of the wait — the
          # real handoff may still be on its way — so only a good payload
          # stops the listener.
          var good = false
          try:
            discard tokensOf(body)
            good = true
          except CatchableError as e:
            trace("oauth", "ignoring a POST: " & e.msg)
          client.send(httpResponse(if good: "200 OK" else: "400 Bad Request",
                                   "text/plain; charset=utf-8",
                                   if good: "ok" else: "bad payload"))
          if good:
            client.close()
            events.send("ok: " & body.strip())
            return
        else:
          client.send(httpResponse("200 OK", "text/html; charset=utf-8",
                                   captureHtml()))
      finally:
        try: client.close() except CatchableError: discard

    events.send(if cancelled: "error: Sign-in cancelled."
                else: "error: The browser did not come back — sign in again.")
  except CatchableError as e:
    trace("oauth", "!! " & e.msg)
    events.send("error: " & e.msg)
  finally:
    try: server.close() except CatchableError: discard

proc begin*(broker, handle: string, openBrowser = true) =
  ## Open the browser and start waiting. Returns at once; what happens next
  ## arrives through `tryEvent`.
  ##
  ## `openBrowser` is off in the test that drives the loopback listener for
  ## real, which otherwise opens a tab on whoever runs the suite. The login
  ## URL goes out on the channel either way — it is on the screen for the
  ## machine that has no `xdg-open`, and that is the same string a test
  ## posts back to.
  if running:
    trace("oauth", "a sign-in is already waiting")
    return
  while events.tryRecv()[0]: discard
  cancelled = false
  running = true
  createThread(worker, workerBody,
               LoginReq(broker: broker, handle: handle,
                        openBrowser: openBrowser))

proc cancel*() =
  ## Stop waiting. The thread notices within the second it is sleeping in.
  if running: cancelled = true

proc tryEvent*(): (bool, string) = events.tryRecv()

proc finished*() =
  ## Called by the drain once an event has settled the wait.
  running = false
  cancelled = false

proc waiting*(): bool = running

events.open()
