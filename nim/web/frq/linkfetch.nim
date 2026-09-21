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
##
## What differs is who is asked. The desktop asks freeq directly; a page may
## not. freeq answers `access-control-allow-origin` for five origins it
## knows and this bundle is served from none of them, so the fetch is made,
## answered, and the answer withheld — which is what happened the first time
## this shipped, and read on the screen as a feature that simply did not
## work. So the page asks its own server for its own path and that server
## relays, exactly as `/api/v1/upload` already does. `tools/webserve.py`.

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
  # A path and not a URL: same-origin, so there is no preflight, no
  # allowlist and no CORS at all. `host` is the freeq this client is talking
  # to and is not used here — the relay's upstream is its own, set where it
  # runs rather than by whatever the page asks for.
  let endpoint = ogPath(url)
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
