## Tab in the compose box: completing, cycling, and the caret.

import std/unittest
import frq/complete

let nicks = @["alice", "alicia", "bob", "nandi.uk"]
let chans = @["#general", "#freeq", "#test"]

proc tab(text: string, prev = TabState(), back = false,
         caret = -1): TabState =
  tabComplete(text, (if caret < 0: text.len else: caret), nicks, chans,
              prev, back)

suite "tabComplete":
  test "one match at the start of a line is addressed":
    check tab("bo").text == "bob: "
  test "one match mid-line is mentioned":
    check tab("hi bo").text == "hi bob "
  test "case is ignored and the nick's own case lands":
    check tab("hi NAN").text == "hi nandi.uk "
  test "an @ stays in front and gets no colon":
    check tab("@bo").text == "@bob "
  test "no match leaves the draft alone":
    check not tab("zz").active
    check not tab("").active
    check not tab("hi ").active

  test "several matches: as far as they agree, then cycle":
    let a = tab("a")
    check a.text == "alic"
    let b = tab(a.text, a)
    check b.text == "alice: "
    let c = tab(b.text, b)
    check c.text == "alicia: "
    check tab(c.text, c).text == "alice: "

  test "Shift-Tab cycles backwards":
    let a = tab("alic")
    check a.text == "alice: "
    check tab(a.text, a, back = true).text == "alicia: "

  test "a typed letter starts over":
    let a = tab("alic")
    check tab("alici", a).text == "alicia: "

  test "channels complete on #":
    check tab("join #gen").text == "join #general "
    let f = tab("#")
    check f.active

  test "completing in the middle keeps the rest of the line":
    let t = tab("bo said hi", caret = 2)
    check t.text == "bob: said hi"
    check t.caret == "bob:".len
    check not tab(t.text, t, caret = t.caret).active

suite "offsets":
  test "UTF-16 and bytes agree on ASCII":
    check byteOffset("hello", 3) == 3
    check utf16Offset("hello", 3) == 3
  test "a two-byte letter and an astral emoji":
    let s = "é😀x"
    check byteOffset(s, 1) == 2
    check byteOffset(s, 3) == 6
    check utf16Offset(s, 6) == 3
    check utf16Offset(s, s.len) == 4

suite "byRecency":
  test "last speaker first, then alphabetical, self last":
    check byRecency(@["carol", "bob", "me", "alice"],
                    @["alice", "bob", "me", "alice"], "me") ==
          @["alice", "bob", "carol", "me"]
    check byRecency(@["carol", "bob", "alice"], @["bob", "carol"], "me") ==
          @["carol", "bob", "alice"]
