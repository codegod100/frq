## What is at the end of a link. No network: every case here is a URL in and
## an answer out, or a body in and a card's fields out.

import std/[json, strutils, unittest]
import frq/links

suite "previewable":
  test "a web page is":
    check previewable("https://example.com/a-post")
    check previewable("http://example.com")
  test "a picture is not — it already draws itself inline":
    check not previewable("https://x.com/a.png")
    check not previewable("https://x.com/A.JPEG")
  test "nor is a media file, which has no HTML to read":
    check not previewable("https://x.com/song.mp3")
    check not previewable("https://x.com/clip.webm")
  test "an extension in the query string is not the path's":
    check previewable("https://example.com/page?img=a.png")
  test "freeq's own API is not a page":
    check not previewable("https://irc.freeq.at/api/v1/media/abc")
  test "nor is a link to somebody's own machine, which freeq will not fetch":
    check not previewable("http://127.0.0.1:11434")
    check not previewable("http://localhost:8080/x")
    check not previewable("http://192.168.1.10/")
    check not previewable("http://10.0.0.1/")
    check not previewable("http://172.20.0.1/")
    check not previewable("http://[::1]:3000/")
    check not previewable("http://printer.local/")
    check previewable("http://172.32.0.1/")
    check previewable("https://127.example.com/")
  test "nor is something that is not a URL at all":
    check not previewable("example.com")
    check not previewable("")

suite "firstPreviewUrl":
  test "the first link that is a page":
    check firstPreviewUrl("see https://example.com/x now") ==
      "https://example.com/x"
  test "only the first — four cards for one line is a screenful":
    check firstPreviewUrl("https://a.example/1 https://b.example/2") ==
      "https://a.example/1"
  test "a picture is skipped in favour of the page after it":
    check firstPreviewUrl("https://x.com/a.png and https://example.com") ==
      "https://example.com"
  test "a line with no link has none":
    check firstPreviewUrl("just words") == ""

suite "domainOf":
  test "the host, without the www":
    check domainOf("https://www.example.com/a/b?c=d") == "example.com"
    check domainOf("https://news.example.com") == "news.example.com"
  test "a port and userinfo are not the host":
    check domainOf("http://example.com:8080/x") == "example.com"
    check domainOf("https://user@example.com/x") == "example.com"

suite "ogPath":
  test "a path, for a page that must ask its own server":
    check ogPath("https://example.com/a b") ==
      "/api/v1/og?url=https%3A%2F%2Fexample.com%2Fa%20b"
  test "a space is %20 and not a plus, so a literal plus survives":
    check ogPath("https://e.com/a+b") == "/api/v1/og?url=https%3A%2F%2Fe.com%2Fa%2Bb"

suite "ogEndpoint":
  test "freeq's proxy, on the server we are connected to":
    check ogEndpoint("irc.freeq.at", "https://example.com/a b") ==
      "https://irc.freeq.at/api/v1/og?url=https%3A%2F%2Fexample.com%2Fa%20b"
  test "the IRC port has nothing to do with the REST side":
    check ogEndpoint("irc.freeq.at:6697", "https://e.com").startsWith(
      "https://irc.freeq.at/api/v1/og?")
  test "no host, no endpoint":
    check ogEndpoint("", "https://e.com") == ""

suite "parsePreview":
  test "the fields the card paints":
    let p = parsePreview(%*{"title": "A post", "description": "About it",
                            "image": "https://e.com/i.png",
                            "site_name": "Example"})
    check p.status == lsReady
    check p.title == "A post"
    check p.description == "About it"
    check p.image == "https://e.com/i.png"
    check p.siteName == "Example"
  test "a page with no OpenGraph answers with nulls, and that is a failure":
    # Rather than an empty card, which would be a row about this client.
    check parsePreview(%*{"title": newJNull(), "description": newJNull(),
                          "image": newJNull(),
                          "site_name": newJNull()}).status == lsFailed
  test "a description alone is not enough to draw":
    check parsePreview(%*{"description": "only this"}).status == lsFailed
  test "a picture alone is":
    check parsePreview(%*{"image": "https://e.com/i.png"}).status == lsReady

suite "the cache":
  setup:
    forgetPreviews()
  test "nothing is known until it is remembered":
    check not known("https://e.com")
    let (_, has) = lookup("https://e.com")
    check not has
  test "and then it is":
    remember("https://e.com", Preview(status: lsReady, title: "T"))
    check known("https://e.com")
    let (p, has) = lookup("https://e.com")
    check has
    check p.title == "T"
