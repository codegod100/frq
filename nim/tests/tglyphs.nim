## Splitting a line into words and pictures.

import std/[sequtils, strutils, unittest]
import frq/[glyphs, emoji]

proc kinds(s: string): seq[RunKind] = runs(s).mapIt(it.kind)
proc values(s: string): seq[string] = runs(s).mapIt(it.value)

suite "the catalogue":
  test "is the whole of Unicode's list, filtered to what can be drawn":
    check catalog.len == 1884
    check popular.len == 16
    check groups.len == 9
  test "every entry has all three fields":
    for e in catalog:
      check e.glyph.len > 0
      check e.name.len > 0
      check e.group.len > 0

suite "runs":
  test "plain text is one run":
    check kinds("hello") == @[gkText]
    check values("hello") == @["hello"]

  test "a bare emoji is one picture":
    check kinds("👍") == @[gkEmoji]
    check values("👍") == @["👍"]

  test "text around an emoji":
    check kinds("hi 👍 there") == @[gkText, gkEmoji, gkText]
    check values("hi 👍 there") == @["hi ", "👍", " there"]

  test "two emoji side by side are two runs":
    # A node draws one picture.
    check kinds("👍🎉") == @[gkEmoji, gkEmoji]

  test "empty text is no runs":
    check runs("").len == 0

  test "a family is one glyph, not its parts":
    # 👨 is the head of 👨‍👩‍👧; taking the man would leave his family as
    # three more glyphs and two tofu joiners.
    let got = runs("👨‍👩‍👧")
    check got.len == 1
    check got[0].kind == gkEmoji

  test "a toned emoji is one picture, and keeps its tone":
    # The catalogue leaves toned variants out; the pack has them, so the tone
    # is stripped for the lookup and kept for the drawing.
    let got = runs("👍🏽")
    check got.len == 1
    check got[0].kind == gkEmoji
    check "🏽" in got[0].value

  test "a character the pack has no picture for stays text":
    check kinds("←") == @[gkText]   # ← is not in the pack

  test "non-ASCII text that is not emoji is left alone":
    check values("héllo wörld") == @["héllo wörld"]

suite "hasEmoji":
  test "yes":
    check runs("a 👍").hasEmoji
  test "no":
    check not runs("just words").hasEmoji

suite "pickerEmoji":
  test "nothing selected shows the popular row":
    let got = pickerEmoji("", "")
    check got.len == popular.len
    check got[0].glyph == popular[0]

  test "a group shows that group":
    let got = pickerEmoji("", "Flags")
    check got.len > 0
    check got.allIt(it.group == "Flags")

  test "search finds by name":
    let got = pickerEmoji("grinning", "")
    check got.len > 0
    check got.allIt("grinning" in it.name.toLower())

  test "search finds the cat and the cat face":
    check pickerEmoji("cat", "").len > 1

  test "search finds a pasted glyph":
    let got = pickerEmoji("👍", "")
    check got.len == 1
    check got[0].glyph == "👍"

  test "search beats a selected group":
    # A search is what the reader just typed; the group is where they were.
    check pickerEmoji("grinning", "Flags").allIt(it.group != "Flags")
