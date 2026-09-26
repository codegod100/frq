## Going and getting a profile, in a browser.
##
## The desktop runs a worker thread with a channel each way. Here the shape is
## the same and the machinery is nothing: `want` asks JavaScript to fetch, the
## answer comes back through `arrived`, and `collect` folds it in — the same
## three steps, with `fetch` and a callback where the other has a thread and a
## channel.
##
## That the desktop's version is already asynchronous is why this fits at all.
## A blocking fetch would have had nowhere to go.

import std/[deques, json]
import frq/profile

var answers: Deque[(string, string)]   ## actor, body — the body empty on failure

{.emit: """
function frqFetchProfile(actor, done) {
  fetch("/api/v1/profile?actor=" + encodeURIComponent(actor))
    .then(function (r) { return r.ok ? r.text() : ""; })
    .then(function (t) { done(actor, t); })
    .catch(function () { done(actor, ""); });
}
""".}

proc fetchProfile(actor: cstring, done: proc (a, b: cstring))
  {.importc: "frqFetchProfile".}

proc arrived(actor, body: cstring) =
  answers.addLast(($actor, $body))

proc want*(actor: string) =
  ## Once per identity for the run, as on the desktop: `psLoading` goes in the
  ## cache here, so a second ask while the first is in flight is not a second
  ## round trip.
  if actor.len == 0 or known(actor) or isAgent(actor): return
  remember(actor, Profile(status: psLoading))
  fetchProfile(actor.cstring, arrived)

proc collect*(): bool =
  ## Fold whatever has come back into the cache. True where anything did.
  while answers.len > 0:
    let (actor, body) = answers.popFirst()
    remember(actor,
      if body.len == 0: Profile(status: psFailed)
      else:
        try:
          let j = parseJson(body)
          if j{"did"}.getStr().len > 0: parseProfile(j)
          else: Profile(status: psFailed)
        except CatchableError: Profile(status: psFailed))
    result = true
