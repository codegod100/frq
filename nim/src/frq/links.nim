## What is at the end of a link, for the card under the message.
##
## The cache the screens read, and the pure string work around it. The half
## that fetches is `linkfetch`, split off for the reason `profile` and
## `profilefetch` are split: a screen asks what is known and never for it to
## be found out, and a screen that reached an HTTP client could not be
## compiled for a target without sockets.
##
## The metadata is OpenGraph, and it comes from one of two places. freeq
## carries a sender's own preview on the message as `+freeq.at/link-*` tags,
## which is the better answer where it is there: it is signed with the line
## and it costs nothing. Where it is not, freeq's own server will fetch the
## page and hand back the tags — `GET /api/v1/og?url=`. Asking the server
## rather than the page is what keeps a reader's browsing off every host
## somebody pastes a link to, and is why there is no direct fetch here even
## on the desktop, where one would work.

import std/[json, strutils, tables, uri]
import frq/textruns

type
  PreviewStatus* = enum
    lsLoading = "loading", lsReady = "ready", lsFailed = "failed"

  Preview* = object
    status*: PreviewStatus
    title*, description*, siteName*, image*: string

var cache: Table[string, Preview]

func previewable*(url: string): bool =
  ## Whether this link is a web page worth a card.
  ##
  ## A picture already draws itself inline, a media file has nothing to say
  ## about itself in HTML, and freeq's own API URLs are not pages at all —
  ## asking about any of them is a round trip that can only come back empty.
  if not (url.startsWith("http://") or url.startsWith("https://")): return false
  let low = url.toLowerAscii
  if low.contains("/api/v1/"): return false
  for ext in [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg",
              ".mp3", ".m4a", ".mp4", ".mov", ".webm", ".ogg", ".wav", ".aac",
              ".pdf", ".zip"]:
    # The extension at the end of the path, not anywhere in the URL: a query
    # string that mentions `.png` is still a page.
    var stop = low.len
    for i, c in low:
      if c in {'?', '#'}:
        stop = i
        break
    if low[0 ..< stop].endsWith(ext): return false
  true

func firstPreviewUrl*(text: string): string =
  ## The one link in a message that gets a card, or "".
  ##
  ## The first, and only the first: a line with four links in it is a line
  ## about the links, and four cards under it is a screenful for one message.
  for r in textRuns(text):
    if r.kind == rkLink and previewable(r.value):
      return r.value
  ""

func domainOf*(url: string): string =
  ## `news.example.com` out of a URL, without the `www.` — what the card says
  ## it is showing you, and the one part of a link a reader reads.
  var rest = url
  let scheme = rest.find("://")
  if scheme >= 0: rest = rest[scheme + 3 .. ^1]
  for i, c in rest:
    if c in {'/', '?', '#'}:
      rest = rest[0 ..< i]
      break
  let at = rest.rfind('@')          # userinfo, which is not the host
  if at >= 0: rest = rest[at + 1 .. ^1]
  let colon = rest.find(':')        # a port
  if colon >= 0: rest = rest[0 ..< colon]
  rest = rest.toLowerAscii
  if rest.startsWith("www."): rest[4 .. ^1] else: rest

func ogPath*(url: string): string =
  ## freeq's preview proxy as a path, without a host on the front.
  ##
  ## Two callers want different halves of the same thing. The desktop asks
  ## the server directly and needs the whole URL; the page may not — freeq
  ## answers `access-control-allow-origin` for its own five origins and this
  ## bundle is served from none of them — so it asks its own server for this
  ## path and that server relays. Same reason `/api/v1/upload` is relayed,
  ## and the same fixed upstream: `tools/webserve.py` says the rest.
  ##
  ## `usePlus = false`: a space comes out as %20 rather than as `+`, which is
  ## form encoding and would make a literal plus — a real character in a path
  ## — have to be escaped to survive. %20 is right for both.
  "/api/v1/og?url=" & encodeUrl(url, usePlus = false)

func ogEndpoint*(host, url: string): string =
  ## That path on the server this client is connected to, for a host that may
  ## make the request itself.
  ##
  ## Port 6697 is the IRC socket and has nothing to do with this; the REST
  ## side is plain HTTPS, so whatever port the form carries is dropped.
  var h = host.strip()
  let colon = h.find(':')
  if colon >= 0: h = h[0 ..< colon]
  if h.len == 0: return ""
  "https://" & h & ogPath(url)

func parsePreview*(body: JsonNode): Preview =
  ## The card's fields out of an `/api/v1/og` answer. Every one of them is
  ## optional there — a page with no OpenGraph at all answers with four
  ## nulls — so a preview with nothing in it is a failure rather than an
  ## empty card.
  result = Preview(status: lsReady,
                   title: body{"title"}.getStr().strip(),
                   description: body{"description"}.getStr().strip(),
                   siteName: body{"site_name"}.getStr().strip(),
                   image: body{"image"}.getStr().strip())
  if result.title.len == 0 and result.image.len == 0:
    result = Preview(status: lsFailed)

proc remember*(url: string, p: Preview) =
  ## Put a preview in the cache. For `linkfetch`, and for the reducer where a
  ## message arrived carrying its own.
  cache[url] = p

proc known*(url: string): bool = cache.hasKey(url)

proc lookup*(url: string): (Preview, bool) =
  ## What is known about this link right now — `lookup` rather than `entry`,
  ## which is what `profile` calls its own, because a screen reads both and
  ## two procs of that name taking a string are ambiguous at the call site.
  ##, and whether anything is. A
  ## lookup and never a fetch: this is called from the render path.
  if cache.hasKey(url): (cache[url], true)
  else: (Preview(), false)

proc setPreviewForTest*(url: string, p: Preview) = cache[url] = p

proc forgetPreviews*() =
  ## For a test that wants a known starting point.
  cache.clear()
