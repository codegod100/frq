## Going and getting a link's preview, off the thread that draws it.
##
## `profilefetch` with a different URL in it, and deliberately so: the shape
## is a worker taking requests off one channel and putting answers on
## another, with `collect` folding them into the cache on the thread that
## owns it. A preview is an HTTPS round trip like a profile, and a backlog of
## a hundred lines is as many of them.
##
## What it asks is freeq's own `/api/v1/og`, never the page. The server
## fetches and parses; this client learns nothing about the host somebody
## linked to, and neither does that host learn about the reader.

import std/[exitprocs, httpclient, json, net, strutils]
import frq/[links, trace]

var
  requests: Channel[string]      ## "<endpoint>\x1f<url>"
  answers: Channel[string]       ## "<url>\x1f<json>", the json empty on failure
  fetcher: Thread[void]
  fetching: bool
  stopping: bool

proc fetchOne(endpoint: string): string =
  ## The body, or "" where there is not one. No socket timeout, for the
  ## reason `atproto` gives: a timeout here dies on the first signal.
  var c: HttpClient
  try:
    c = newHttpClient(sslContext = newContext(verifyMode = CVerifyPeer))
    c.getContent(endpoint)
  except CatchableError as e:
    trace("link", "!! " & e.msg)
    ""
  finally:
    if c != nil:
      try: c.close() except CatchableError: discard

proc fetcherBody() {.thread.} =
  {.gcsafe.}:
    while true:
      let job = requests.recv()
      if job.len == 0 or stopping: break
      let sep = job.find('\x1f')
      if sep < 0: continue
      let endpoint = job[0 ..< sep]
      let url = job[sep + 1 .. ^1]
      trace("link", "GET " & endpoint)
      answers.send(url & "\x1f" & fetchOne(endpoint))

proc want*(host, url: string) =
  ## Ask for a preview, without waiting for it.
  ##
  ## Once per link for the run: `lsLoading` goes in the cache here, so the
  ## same URL pasted twice in a room is one round trip, and a re-render while
  ## the first is in flight is not a second.
  if url.len == 0 or known(url) or not previewable(url): return
  let endpoint = ogEndpoint(host, url)
  if endpoint.len == 0: return
  remember(url, Preview(status: lsLoading))
  if not fetching:
    fetching = true
    createThread(fetcher, fetcherBody)
  requests.send(endpoint & "\x1f" & url)

proc stopFetching() =
  ## Stop the worker and wait for it, at exit — the SIGSEGV inside
  ## `net.newContext` that `profilefetch` documents is this thread's too.
  if not fetching: return
  stopping = true
  requests.send("")
  joinThread(fetcher)
  fetching = false

addExitProc(stopFetching)

proc collect*(): bool =
  ## Fold whatever has come back into the cache. True where anything did, so
  ## a caller knows the screen has something new on it.
  while true:
    let (ok, msg) = answers.tryRecv()
    if not ok: break
    let sep = msg.find('\x1f')
    if sep < 0: continue
    let url = msg[0 ..< sep]
    let body = msg[sep + 1 .. ^1]
    remember(url,
      if body.len == 0: Preview(status: lsFailed)
      else:
        try: parsePreview(parseJson(body))
        except CatchableError: Preview(status: lsFailed))
    result = true

requests.open()
answers.open()
