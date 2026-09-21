## A revision folded into the buffer, and a line taken out of it.

import std/[tables, unittest]
import frq/[model, edits]

proc roomWith(msgs: varargs[Message]): OrderedTable[string, Room] =
  var r = initRoom("#test")
  for m in msgs: r.messages.add m
  result = initOrderedTable[string, Room]()
  result["#test"] = r

suite "applyEdit":
  test "the sender's own line is rewritten in place":
    var rooms = roomWith(Message(id: "m1", frm: "ann", text: "helo"))
    check rooms.applyEdit("#test", "m1", "ann", "hello", "m2") == erApplied
    check rooms["#test"].messages.len == 1
    check rooms["#test"].messages[0].text == "hello"
    check rooms["#test"].messages[0].edited
    # The line keeps the id it was born with; the revision's own id joins it,
    # so a reply naming either still finds this line.
    check rooms["#test"].messages[0].id == "m1"
    check "m2" in rooms["#test"].messages[0].editIds

  test "somebody else's line is not theirs to rewrite":
    var rooms = roomWith(Message(id: "m1", frm: "ann", text: "helo"))
    check rooms.applyEdit("#test", "m1", "bob", "words", "") == erRefused
    check rooms["#test"].messages[0].text == "helo"

  test "an edit of something older than the backlog is absent":
    var rooms = roomWith(Message(id: "m1", frm: "ann", text: "helo"))
    check rooms.applyEdit("#test", "m0", "ann", "hello", "") == erAbsent

suite "applyDelete":
  test "the line stops being on screen":
    var rooms = roomWith(Message(id: "m1", frm: "ann", text: "oops"),
                         Message(id: "m2", frm: "bob", text: "hi"))
    check rooms.applyDelete("#test", "m1")
    check rooms["#test"].messages.len == 1
    check rooms["#test"].messages[0].id == "m2"

  test "a delete for a line we never had is not an error":
    var rooms = roomWith(Message(id: "m1", frm: "ann", text: "oops"))
    check not rooms.applyDelete("#test", "m9")
