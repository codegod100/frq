## The broker handoff, in a browser — which is the easy half of it.
##
## A desktop has to catch the broker's answer: bind a loopback port, open a
## browser at it, serve a page whose one job is to post the fragment back.
## None of that is needed here, because the browser *is* the thing being
## redirected. `begin` sends the page to the broker; the broker sends it back
## with the payload in the fragment; the host reads the fragment and calls
## `handoff`.
##
## `oauthcore` holds the parts that are the same either way — the login URL,
## and the payload once it is in hand.

import std/[deques, strutils]
import frq/[oauthcore, trace]
export oauthcore

var
  events: Deque[string]   ## "url: …" | "ok: …" | "error: …"
  running: bool

{.emit: """
function frqGoTo(url) { window.location.href = url; }
function frqHere() {
  // Without the fragment: `return_to` is where the broker sends the reader
  // back, and it must be this page rather than this page plus whatever is
  // already hanging off it.
  return window.location.origin + window.location.pathname;
}
function frqRefreshSession(broker, token, done) {
  fetch("https://" + broker + "/session", {
    method: "POST",
    headers: {"Content-Type": "application/json"},
    body: JSON.stringify({broker_token: token}),
  }).then(function (r) { return r.text(); })
    .then(function (t) { done(t); })
    .catch(function (e) { done(""); });
}
""".}

proc goTo(url: cstring) {.importc: "frqGoTo".}
proc here(): cstring {.importc: "frqHere".}

proc begin*(broker, handle: string, openBrowser = true) =
  ## Leave for the broker. There is no waiting to do: this page is about to
  ## stop existing, and what comes back comes back as a fresh load with the
  ## payload in the fragment.
  running = true
  let url = loginUrl(broker, handle, $here())
  trace("oauth", "leaving for " & url)
  events.addLast("url: " & url)
  goTo(url.cstring)

proc handoff*(payload: string) =
  ## The fragment this page came back with, from the host.
  if payload.len == 0: return
  running = true
  events.addLast("ok: " & payload.strip())

proc failed*(reason: string) =
  running = true
  events.addLast("error: " & reason)

proc cancel*() = running = false
proc finished*() = running = false
proc waiting*(): bool = running
proc tryEvent*(): (bool, string) =
  if events.len == 0: (false, "") else: (true, events.popFirst())

proc refreshSession*(broker, brokerToken: string): Tokens =
  ## Not here. `fetch` is asynchronous and this is not, so on the web a
  ## remembered token is spent by the host: it calls the broker, and hands
  ## what comes back to `handoff` exactly as a fresh sign-in would.
  raise newException(OauthError, "the host refreshes the session on the web")
