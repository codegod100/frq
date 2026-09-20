## The browser handoff, on a desktop.
##
## The pure half — the login URL, the payload, the capture page — is
## `oauthcore`, shared with the web build, which catches the answer by being
## the page that was redirected rather than by listening for it.
##
## The broker at `auth.freeq.at` does the AT Protocol OAuth with the reader's
## own PDS, so this holds no password and no DPoP key. It binds a loopback
## port, opens a browser at `/auth/login?…&return_to=http://127.0.0.1:<port>`,
## and serves a page whose one job is to POST the URL fragment back — a
## fragment never reaches a server.
##
## The wait is a thread for the reason `conn`'s is: a reader takes as long as
## they take over a login page, and `dispatch` is called on the frame.

import std/[httpclient, json, nativesockets, net, osproc, strutils, times]
import frq/[trace, eintr]
import frq/oauthcore
export oauthcore

const
  loginTimeout = 5 * 60   ## seconds; a login page nobody finishes

  hostSignsIn* = false
    ## This host signs in through freeq's broker, which is allowed to redirect
    ## to loopback — and a desktop is loopback. A browser is not, so the web
    ## build says `true` and does the OAuth itself. See `nim/web/frq/oauth`.

proc refreshSession*(broker, brokerToken: string): Tokens =
  ## Mint a fresh web-token from the durable broker token.
  ##
  ## This is what a second run uses: the token that came back through the
  ## browser was spent on the first connection, and the reader should not see
  ## a login page again for it.
  # A client per attempt, and the body read inside it.
  #
  # Neither of those is fussiness. A client whose handshake was cut short is
  # not a client to ask again — the retry rides a half-open connection — and
  # `Response.body` is a stream that is read where it is first touched, so
  # reading it at `parseJson` put the longest blocking call of the round trip
  # outside the very retry meant to cover it. `⚠ Could not reach the broker —
  # Interrupted system call` survived the first fix for that reason.
  var
    c: HttpClient
    status: string
    body: string
  try:
    retrying 3:
      if c != nil:
        try: c.close() except CatchableError: discard
      # No socket timeout, deliberately; see `frq/eintr`.
      c = newHttpClient(sslContext = newContext(verifyMode = CVerifyPeer))
      c.headers = newHttpHeaders({"Content-Type": "application/json"})
      let res = c.request("https://" & brokerHost(broker) & "/session",
                          httpMethod = HttpPost,
                          body = $(%*{"broker_token": brokerToken}))
      status = res.status
      body = res.body
    # The body whatever the status: an expired token is a 401 whose message
    # is the part worth showing.
    let j = try: parseJson(body)
            except CatchableError:
              raise newException(OauthError,
                "The broker's answer was not JSON (" & status & ").")
    let token = j{"token"}.getStr()
    if token.len == 0:
      let m = j{"message"}.getStr()
      raise newException(OauthError,
        if m.len > 0: m else: "Broker session refresh failed — sign in again")
    Tokens(token: token, brokerToken: brokerToken,
           nick: j{"nick"}.getStr(), did: j{"did"}.getStr(),
           handle: j{"handle"}.getStr())
  finally:
    if c != nil:
      try: c.close() except CatchableError: discard

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
        # A signal during accept or the read that follows is not the browser
        # failing to arrive; the wait goes on. See `frq/eintr`.
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
      except CatchableError as e:
        if not interrupted(e): raise
        trace("oauth", "a signal cut a request short; still waiting")
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

proc forgetHostSession*() = discard
  ## Nothing of a sign-in lives on this side: the broker token is the core's,
  ## and `session.forget` has already dropped it. The web host holds a token
  ## and a key and has real work to do here.

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
