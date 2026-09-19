## The naming rules, which are the fiddly part of the model.

import std/[options, unittest]
import frq/model

suite "dm":
  test "a channel is not a DM":
    check not dm("#test")
  test "a nick is":
    check dm("alice")
  test "an empty name is neither":
    check not dm("")

suite "rowId":
  test "the server's name wins":
    check rowId(Message(id: "srv", localId: "loc")) == "srv"
  test "the local name stands in until there is one":
    check rowId(Message(localId: "loc")) == "loc"
  test "a line with neither has no name":
    check rowId(Message()) == ""

suite "answersTo":
  setup:
    let m = Message(id: "b", localId: "a", editIds: @["c", "d"])

  test "the current msgid":
    check m.answersTo("b")
  test "the local id, for a line not yet echoed":
    check m.answersTo("a")
  test "any msgid a revision of it has worn":
    check m.answersTo("c")
    check m.answersTo("d")
  test "not somebody else's":
    check not m.answersTo("z")
  test "an empty id names nothing":
    # Otherwise every line with no msgid answers to every lookup that has
    # none either, and a reply chip points at an arbitrary message.
    check not m.answersTo("")
    check not Message().answersTo("")

suite "messageById":
  setup:
    var ch = initRoom("#test")
    ch.messages = @[Message(id: "1", text: "one"),
                    Message(id: "2", text: "two", editIds: @["2b"])]

  test "finds by msgid":
    check ch.messageById("1").get.text == "one"
  test "finds a revision by the name it wore":
    check ch.messageById("2b").get.text == "two"
  test "answers with nothing for a line it does not hold":
    check ch.messageById("9").isNone
  test "indexById agrees with it":
    check ch.indexById("2") == 1
    check ch.indexById("9") == -1
