## The tree, built only when what it is built from moved.

import std/[json, strutils, tables, unittest]
import frq/[cells, model, reducer, rooms, tree]

proc ev(id: string, value = ""): JsonNode = %*{"id": id, "value": value}

proc chat() =
  app = initState()
  app.formNick = "me"
  app.rooms.ensureRoom("#test")
  app.rooms["#test"].joined = true
  app.current = "#test"
  app.screen = scChat
  app.status = "Connected as me"

suite "refresh":
  test "a state that has not moved is not built again":
    chat()
    discard refresh()
    check not refresh()

  test "a state that moved is":
    chat()
    discard refresh()
    let before = treeJson
    var r = app.rooms["#test"]
    r.messages.add Message(id: "1", frm: "alice", text: "hello there", at: 1)
    app.rooms["#test"] = r
    check refresh()
    check treeJson != before
    check "hello there" in treeJson

  test "a keystroke does not build a tree":
    chat()
    discard refresh()
    input($ev("draft.change", "hel"))
    check app.draft == "hel"
    check not refresh()

  test "a keystroke leaves the revision where it was":
    chat()
    let rev = app.draftRev
    dispatch(ev("draft.change", "hello"))
    check app.draftRev == rev

  test "a send that empties the draft moves the revision, and builds":
    chat()
    discard refresh()
    input($ev("draft.change", "hello"))
    let rev = app.draftRev
    dispatch(ev("send"))
    check app.draft == ""
    check app.draftRev > rev
    check refresh()
    check ("\"rev\":" & $app.draftRev) in treeJson

  test "an event that leaves the draft alone leaves the revision":
    chat()
    input($ev("draft.change", "hello"))
    let rev = app.draftRev
    dispatch(ev("users.toggle"))
    check app.draftRev == rev
