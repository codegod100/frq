## Who someone is, behind the nick. No network: every case here is a body in
## and fields out, or a question about a nick.

import std/[strutils, unicode]
import std/[json, unittest]
import frq/profile

suite "isHandle":
  test "a domain-shaped nick is a handle":
    check isHandle("alice.bsky.social")
    check isHandle("nandi.uk")
  test "a bare nick is not":
    # freeq gives an authenticated user their handle by default, while
    # `sleek5209` is a guest with no profile.
    check not isHandle("sleek5209")
    check not isHandle("alice")
  test "nor is something with no TLD":
    check not isHandle("alice.")
    check not isHandle("")
  test "a hyphen is fine inside a label, not at its start":
    check isHandle("my-host.example.com")
    check not isHandle("-host.example.com")
    check not isHandle("host.-example.com")
  test "the TLD is two or more letters, and only letters":
    check not isHandle("alice.c")
    check not isHandle("alice.c0m")
    check not isHandle("alice.com-")
  test "no empty labels":
    check not isHandle(".alice.com")
    check not isHandle("alice..com")
  test "nor anything a domain cannot hold":
    check not isHandle("alice bob.com")
    check not isHandle("alice@bsky.social")

suite "actorFor":
  test "a DID wins, because it is the identity itself":
    # A nick is whatever someone chose today.
    check actorFor("did:plc:abc", "alice.bsky.social") == "did:plc:abc"
  test "a handle-shaped nick stands in where there is no DID":
    check actorFor("", "alice.bsky.social") == "alice.bsky.social"
  test "a guest has nothing to look up":
    check actorFor("", "sleek5209") == ""

suite "thumbnailUrl":
  test "asks the CDN for the size we paint":
    # A 170KB portrait downloaded to draw at 24 points is the thing this
    # avoids.
    check thumbnailUrl("https://cdn.bsky.app/img/avatar/plain/did:plc:x/y@jpeg") ==
      "https://cdn.bsky.app/img/avatar_thumbnail/plain/did:plc:x/y@png"
  test "replaces an existing format suffix rather than appending":
    check thumbnailUrl("https://cdn/x@jpeg").endsWith("@png")
    check "@jpeg" notin thumbnailUrl("https://cdn/x@jpeg")
  test "no picture is no URL":
    check thumbnailUrl("") == ""

suite "parseProfile":
  let body = parseJson("""{
    "did": "did:plc:abc", "handle": "alice.bsky.social",
    "displayName": "  Alice  ", "description": "  hello  ",
    "avatar": "https://cdn.bsky.app/img/avatar/plain/did:plc:abc/p@jpeg",
    "followersCount": 12, "followsCount": 34, "postsCount": 56 }""")

  test "the fields the panel paints":
    let p = parseProfile(body)
    check p.status == psReady
    check p.did == "did:plc:abc"
    check p.handle == "alice.bsky.social"
    check p.displayName == "Alice"      # trimmed
    check p.description == "hello"
    check p.followers == 12
    check p.avatar.endsWith("@png")

  test "a body with nothing in it":
    let p = parseProfile(parseJson("{}"))
    check p.did == ""
    check p.avatar == ""

suite "statsLine":
  test "all three":
    let p = Profile(followers: 12, follows: 34, posts: 56)
    check statsLine(p) == "12 followers · 34 following · 56 posts"
  test "only what is known":
    check statsLine(Profile(posts: 5)) == "5 posts"
  test "none is no line at all":
    check statsLine(Profile()) == ""

suite "webUrl":
  test "by handle where there is one":
    check webUrl(Profile(handle: "alice.bsky.social", did: "did:plc:x")) ==
      "https://bsky.app/profile/alice.bsky.social"
  test "by DID otherwise":
    check webUrl(Profile(did: "did:plc:x")) == "https://bsky.app/profile/did:plc:x"
  test "a leading @ is not part of a handle":
    check webUrl(Profile(handle: "@alice.bsky.social")) ==
      "https://bsky.app/profile/alice.bsky.social"
  test "nobody is no URL":
    check webUrl(Profile()) == ""

suite "truncate":
  test "leaves a short bio alone, line breaks and all":
    # The height of a multi-line bio is part of what it says.
    check truncate("one\ntwo", 280) == "one\ntwo"
  test "cuts a long one":
    let got = truncate("x".repeat(400), 280)
    check got.runeLen == 280
    check got.endsWith("…")

  test "cuts by character, not by byte":
    let got = truncate("😀".repeat(400), 280)
    check got.runeLen == 280
    check got.validateUtf8 == -1
