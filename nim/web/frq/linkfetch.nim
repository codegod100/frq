## Going and getting a link's preview, in a browser.
##
## The desktop runs a worker thread with a channel each way; here `want` asks
## JavaScript to fetch and `collect` folds the answer in — the same three
## steps with `fetch` and a callback where the other has a thread and a
## queue, exactly as `profilefetch` divides.
##
## Same endpoint, and here it is the only one that would work at all: a page
## cannot read a third-party site's HTML, so `/api/v1/og` is both the private
## answer and the possible one.

import std/deques
import std/json
import frq/links

var answers: Deque[(string, string)]   ## url, body — the body empty on failure

{.emit: """
function frqFetchPreview(endpoint, url, done) {
  fetch(endpoint)
    .then(function (r) { return r.ok ? r.text() : ""; })
    .then(function (t) { done(url, t); })
    .catch(function () { done(url, ""); });
}
""".}

proc fetchPreview(endpoint, url: cstring, done: proc (a, b: cstring))
  {.importc: "frqFetchPreview".}

proc arrived(url, body: cstring) =
  answers.addLast(($url, $body))

proc want*(host, url: string) =
  ## Once per link for the run, as on the desktop.
  if url.len == 0 or known(url) or not previewable(url): return
  let endpoint = ogEndpoint(host, url)
  if endpoint.len == 0: return
  remember(url, Preview(status: lsLoading))
  fetchPreview(endpoint.cstring, url.cstring, arrived)

proc collect*(): bool =
  ## Fold whatever has come back into the cache. True where anything did.
  while answers.len > 0:
    let (url, body) = answers.popFirst()
    remember(url,
      if body.len == 0: Preview(status: lsFailed)
      else:
        try: parsePreview(parseJson(body))
        except CatchableError: Preview(status: lsFailed))
    result = true
