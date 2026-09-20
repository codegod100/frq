## Going and getting a profile, off the thread that draws it.
##
## Split from `profile` because the screens read profiles and must not, by
## importing them, drag in an HTTP client: `screens/chat` reached `profile`,
## which reached `atproto`, which reached `httpclient` and `std/net`. That
## chain is why the UI could not be compiled for a target without sockets,
## and it was a chain nothing needed — a screen asks what is known, never for
## it to be found out.
##
## So this side does the finding out, and `profile` keeps the cache the
## screens read. On the web there is no thread and no `httpclient`; the host
## fetches and hands the answer to `profile.remember`.

import std/[exitprocs, json, strutils]
import frq/[atproto, profile, trace]

# Faces are wanted for everyone in a room at once, and a profile is an HTTPS
# round trip each. Blocking was affordable for the panel — a reader presses a
# face and waits — and is not affordable for a room of twelve, on the thread
# that also answers every keystroke.
#
# So: a worker takes actors off one channel and puts answers on another, and
# `collect` folds them into the cache on the thread that owns it. The cache
# itself is never touched from two threads; only the channels are.

var
  requests: Channel[string]
  answers: Channel[string]   ## "<actor>\x1f<json>", the json empty on failure
  fetcher: Thread[void]
  fetching: bool

var stopping: bool

proc fetcherBody() {.thread.} =
  {.gcsafe.}:
    while true:
      let actor = requests.recv()
      if actor.len == 0 or stopping: break
      var body = ""
      try:
        body = $getProfile(actor)
      except CatchableError as e:
        trace("profile", "could not fetch " & actor & ": " & e.msg)
      answers.send(actor & "\x1f" & body)

proc want*(actor: string) =
  ## Ask for a profile, without waiting for it.
  ##
  ## Once per identity for the run: `psLoading` goes in the cache here, so a
  ## second ask for the same person while the first is in flight is not a
  ## second round trip.
  if actor.len == 0 or known(actor) or isAgent(actor): return
  remember(actor, Profile(status: psLoading))
  if not fetching:
    fetching = true
    createThread(fetcher, fetcherBody)
  requests.send(actor)

proc stopFetching() =
  ## Stop the worker and wait for it, at exit.
  ##
  ## Not tidiness: a thread that is still running when the process tears down
  ## is a thread calling `newContext` after OpenSSL has been unloaded under
  ## it, which is a SIGSEGV inside `net.newContext` reported against whatever
  ## ran last. The test suite found it the first time this landed.
  ##
  ## The sentinel is an empty actor. A request already in flight finishes
  ## first — at worst the HTTP timeout, and in practice the round trip that
  ## was already nearly done.
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
    let actor = msg[0 ..< sep]
    let body = msg[sep + 1 .. ^1]
    remember(actor,
      if body.len == 0: Profile(status: psFailed)
      else:
        try:
          let j = parseJson(body)
          if j{"did"}.getStr().len > 0: parseProfile(j)
          else: Profile(status: psFailed)
        except CatchableError: Profile(status: psFailed))
    result = true

requests.open()
answers.open()
