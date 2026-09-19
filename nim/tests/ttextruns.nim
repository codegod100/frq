## Link detection in message text — the part of the chat screen that is pure
## string work, and the part most worth pinning down.

import std/[sequtils, unittest]
import frq/textruns

proc kinds(s: string): seq[RunKind] = textRuns(s).mapIt(it.kind)
proc values(s: string): seq[string] = textRuns(s).mapIt(it.value)

suite "textRuns":
  test "plain text is one run":
    check kinds("hello there") == @[rkText]
    check values("hello there") == @["hello there"]

  test "a bare URL is one link":
    check kinds("https://example.com") == @[rkLink]

  test "text around a link":
    check kinds("see https://example.com now") == @[rkText, rkLink, rkText]
    check values("see https://example.com now") ==
      @["see ", "https://example.com", " now"]

  test "two links in one line":
    check kinds("a http://x.com b https://y.com") ==
      @[rkText, rkLink, rkText, rkLink]

  test "http as well as https":
    check kinds("http://example.com") == @[rkLink]

  test "the message's own ends are trimmed":
    check values("  hello  ") == @["hello"]

  test "but spaces between words are somebody's typing":
    check values("a  b") == @["a  b"]

  test "empty text is no runs":
    check textRuns("").len == 0

  test "whitespace-only text is no runs, not an empty one":
    check textRuns("   ").len == 0

suite "trimTrailingPunctuation":
  test "a sentence's full stop is not part of the URL":
    check trimTrailingPunctuation("https://x.com.") == "https://x.com"
    check trimTrailingPunctuation("https://x.com,") == "https://x.com"
    check trimTrailingPunctuation("https://x.com?") == "https://x.com"

  test "several at once":
    check trimTrailingPunctuation("https://x.com...") == "https://x.com"

  test "a closing bracket goes when the URL opened none":
    check trimTrailingPunctuation("https://x.com)") == "https://x.com"

  test "but stays when it did — a wikipedia path keeps its brackets":
    check trimTrailingPunctuation("https://en.wikipedia.org/wiki/Foo_(bar)") ==
      "https://en.wikipedia.org/wiki/Foo_(bar)"

  test "the trimmed punctuation comes back as text":
    # Not dropped: somebody typed it.
    check values("see https://x.com. ok") == @["see ", "https://x.com", ". ok"]

suite "firstImageUrl":
  test "a png link":
    check firstImageUrl("look https://x.com/a.png yes") == "https://x.com/a.png"
  test "a freeq media link":
    check firstImageUrl("https://irc.freeq.at/api/v1/media/a/b/picture.png") ==
      "https://irc.freeq.at/api/v1/media/a/b/picture.png"
  test "no picture at all":
    check firstImageUrl("just words and https://x.com/page") == ""
  test "the first one wins":
    check firstImageUrl("https://a.com/1.png https://b.com/2.png") ==
      "https://a.com/1.png"
