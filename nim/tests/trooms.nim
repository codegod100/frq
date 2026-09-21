## The list, the overview and the read marker.
import std/algorithm
import std/strutils
##
## The marker rules are the ones worth the most here: unread is derived rather
## than counted precisely so a replayed backlog cannot inflate it, and these
## are the cases that prove it.

import std/[sequtils, tables, unittest]
import frq/[model, rooms]

proc msg(frm, text: string, at: int64 = 0, id = "", system = false): Message =
  Message(frm: frm, text: text, at: at, id: id, system: system)

suite "channelList":
  setup:
    var chans = initOrderedTable[string, Room]()
    for (n, acc) in [("#alpha", 0'i64), ("#beta", 5'i64), ("#gamma", 9'i64)]:
      var c = initRoom(n); c.accessed = acc; chans[n] = c

  test "most recently opened first":
    check channelList(chans, "").mapIt(it.name) == @["#gamma", "#beta", "#alpha"]

  test "never-opened buffers sort under those, by name":
    chans["#aaa"] = initRoom("#aaa")
    chans["#zzz"] = initRoom("#zzz")
    let names = channelList(chans, "").mapIt(it.name)
    check names == @["#gamma", "#beta", "#aaa", "#alpha", "#zzz"]

  test "the search box filters, case-insensitively":
    check channelList(chans, "BET").mapIt(it.name) == @["#beta"]
  test "a blank search filters nothing":
    check channelList(chans, "   ").len == 3

suite "seenMessage":
  test "a msgid we already hold is a replay":
    let msgs = @[msg("a", "hi", id = "1")]
    check seenMessage(msgs, "1", "a", "hi", "me")
    check not seenMessage(msgs, "2", "a", "hi", "me")

  test "an untagged line is known by its sender and words":
    # A replayed line with no tags has no identity, so left alone it arrives
    # new on every rejoin and the room can never be finished reading.
    let msgs = @[msg("alice", "hello")]
    check seenMessage(msgs, "", "alice", "hello", "me")
    check not seenMessage(msgs, "", "alice", "different", "me")

  test "our own untagged line is never a replay":
    # A second "ok" from this client is a real event.
    let msgs = @[msg("me", "ok")]
    check not seenMessage(msgs, "", "me", "ok", "me")

  test "nor is the system's":
    let msgs = @[msg("*", "alice joined")]
    check not seenMessage(msgs, "", "*", "alice joined", "me")

suite "the read marker":
  setup:
    var ch = initRoom("#test")
    ch.messages = @[msg("a", "one", at = 100, id = "1"),
                    msg("b", "two", at = 200, id = "2"),
                    msg("c", "three", at = 300, id = "3")]

  test "everything after the marked id is unread":
    ch.lastReadId = "1"
    check ch.afterMarker.mapIt(it.text) == @["two", "three"]

  test "by time when the marked line is no longer held":
    ch.lastReadId = "gone"
    ch.lastReadAt = 150
    check ch.afterMarker.mapIt(it.text) == @["two", "three"]

  test "a replayed backlog cannot inflate the count":
    # The whole reason unread is derived rather than counted. Two guards act
    # together and this checks the pair, because either alone is not enough:
    #
    #   seenMessage keeps the replayed line out of the buffer, and
    #   afterMarker means a line that IS older than the marker counts nothing.
    #
    # The first draft of this test appended the backlog twice and expected
    # zero, which is a state seenMessage exists to make impossible — and the
    # Clojure answers three to it as well. A test for an unreachable state
    # tells you nothing about the reachable ones.
    let marked = ch.markRead
    check marked.recount("me").unread == 0
    for m in ch.messages:
      check seenMessage(marked.messages, m.id, m.frm, m.text, "me")

  test "a line older than the marker counts for nothing":
    ch.lastReadId = ""
    ch.lastReadAt = 250
    check ch.afterMarker.mapIt(it.text) == @["three"]

  test "markRead never walks the marker backwards":
    ch.lastReadAt = 500          # read past a backlog that then arrived
    let marked = ch.markRead
    check marked.lastReadAt == 500

  test "system lines are read but never make a room worth looking at":
    ch.messages.add msg("*", "you joined", at = 400, system = true)
    check ch.recount("me").unread == 4 - 1  # the three said lines only... 
    ch.lastReadId = "3"
    check ch.recount("me").unread == 0

  test "a mention is noticed, and only somebody else's":
    ch.messages = @[msg("alice", "hey me, look", at = 100),
                    msg("me", "me me me", at = 200)]
    let r = ch.recount("me")
    check r.unread == 2
    check r.mention

  test "no mention where the reader is not named":
    ch.messages = @[msg("alice", "nothing here", at = 100)]
    check not ch.recount("me").mention

suite "recentEverywhere":
  setup:
    var chans = initOrderedTable[string, Room]()
    for n in ["#a", "#b"]:
      var c = initRoom(n)
      for i in 1 .. 3:
        c.messages.add msg("u", n & $i, at = i.int64 * 10)
      chans[n] = c

  test "the room being read is left out":
    let names = recentEverywhere(chans, "#a").mapIt(it.text)
    check names.allIt(it.startsWith("#b"))

  test "system lines are left out":
    var c = initRoom("#c")
    c.messages = @[msg("*", "joined", at = 99, system = true)]
    chans["#c"] = c
    check recentEverywhere(chans, "").allIt(it.text != "joined")

  test "oldest first, the way a conversation runs":
    # The strip scrolls now, so the newest belongs at the bottom where the
    # eye finishes and where it is in every backlog beside it. Newest-first
    # was right while nothing here scrolled and the top was all there was.
    let ats = recentEverywhere(chans, "").mapIt(it.at)
    check ats == ats.sorted(SortOrder.Ascending)

  test "a turn each, so a busy room cannot crowd a quiet one out":
    # The reason for round-robin: taking the newest N outright would answer
    # about whichever room is busiest, which is the one you can already see.
    var busy = initRoom("#busy")
    for i in 1 .. 200:
      busy.messages.add msg("u", "spam" & $i, at = i.int64)
    chans["#busy"] = busy
    let got = recentEverywhere(chans, "")
    check got.anyIt(it.text.startsWith("#a"))
    check got.len <= overviewLimit

suite "adoptEcho":
  setup:
    var r = initRoom("#test")
    r.messages = @[msg("alice", "hello", at = 100, id = "1")]
    # What `sendDraft` leaves behind: shown at once, no msgid yet.
    r.messages.add Message(frm: "me", text: "hi there", at: 200,
                           localId: "local-1", pending: true)

  test "our own line coming back folds onto the copy we showed":
    # This is the bug: without it every sent message appeared twice, because
    # echo-message is negotiated and the server sends it back with an id.
    check r.adoptEcho("me", "hi there", "srv-9", 250, "did:plc:me")
    check r.messages.len == 2
    check r.messages[1].id == "srv-9"
    check not r.messages[1].pending

  test "and that is how the client learns the msgid":
    # Which is the whole point of asking for the cap: a reaction or a reply
    # aimed at our own line has nothing to name until this happens.
    discard r.adoptEcho("me", "hi there", "srv-9", 250, "")
    check r.messages[1].answersTo("srv-9")
    check rowId(r.messages[1]) == "srv-9"

  test "the server's timestamp wins over ours":
    discard r.adoptEcho("me", "hi there", "srv-9", 250, "")
    check r.messages[1].at == 250

  test "a line that is not ours is not adopted":
    check not r.adoptEcho("alice", "hello", "srv-9", 250, "")

  test "nor is one we have already seen back":
    check r.adoptEcho("me", "hi there", "srv-9", 250, "")
    # A second "hi there" from this client is a real event, not an echo.
    check not r.adoptEcho("me", "hi there", "srv-10", 260, "")

  test "the same text sent twice adopts oldest first":
    # The server echoes in the order it received.
    r.messages.add Message(frm: "me", text: "hi there", at: 300,
                           localId: "local-2", pending: true)
    check r.adoptEcho("me", "hi there", "srv-A", 310, "")
    check r.messages[1].id == "srv-A"
    check r.messages[2].id == ""
    check r.adoptEcho("me", "hi there", "srv-B", 320, "")
    check r.messages[2].id == "srv-B"

  test "different text is not adopted":
    check not r.adoptEcho("me", "something else", "srv-9", 250, "")

suite "lastVisited":
  ## Where the client puts a returning reader down.
  proc roomAt(name: string, accessed: int64): Room =
    result = initRoom(name)
    result.accessed = accessed

  test "the most recently opened room":
    var t = initOrderedTable[string, Room]()
    t["#a"] = roomAt("#a", 100)
    t["#b"] = roomAt("#b", 300)
    t["#c"] = roomAt("#c", 200)
    check t.lastVisited == "#b"

  test "rooms that were never opened are not a last room":
    # A channel the server put us in, or a DM that arrived while we were
    # elsewhere: `accessed` is zero, and zero is never rather than long ago.
    var t = initOrderedTable[string, Room]()
    t["#a"] = roomAt("#a", 0)
    t["#b"] = roomAt("#b", 0)
    check t.lastVisited == ""

  test "an empty list has no last room":
    var t = initOrderedTable[string, Room]()
    check t.lastVisited == ""

  test "one opened room among unopened ones wins":
    var t = initOrderedTable[string, Room]()
    t["#a"] = roomAt("#a", 0)
    t["#b"] = roomAt("#b", 42)
    t["#c"] = roomAt("#c", 0)
    check t.lastVisited == "#b"
