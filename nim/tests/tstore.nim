## What survives a restart, and what deliberately does not.
##
## Every test here points `XDG_CONFIG_HOME` at a directory of its own, set
## before `frq/store` is touched at all: the alternative is a suite that reads
## and writes the config of whoever runs it, which would both lie about the
## result and cost them their room list.

import std/[json, os, sets, tables, times, unittest]

let sandbox = getTempDir() / "frq-tstore-" & $epochTime()
putEnv("XDG_CONFIG_HOME", sandbox)

import frq/[cells, clock, model, rooms, store, reducer]

proc clean() =
  removeDir(sandbox)
  app = initState()

suite "the config directory":
  test "is under XDG_CONFIG_HOME where there is one":
    check configDir() == sandbox / "frq"

suite "a saved session":
  setup: clean()
  test "round-trips, and says whether there was one":
    check loadSession()[1] == false
    check saveSession(SavedSession(brokerToken: "durable", handle: "alice.uk",
                                   did: "did:plc:a", nick: "alice"))
    let (s, had) = loadSession()
    check had
    check s.brokerToken == "durable"
    check s.did == "did:plc:a"
  test "with no broker token is not a session":
    # The token is the whole point of saving one; the handle beside it is
    # only there to say whose it is.
    check saveSession(SavedSession(handle: "alice.uk"))
    check loadSession()[1] == false
  test "is written so nobody else can read it":
    check saveSession(SavedSession(brokerToken: "durable"))
    check getFilePermissions(sessionFile()) == {fpUserRead, fpUserWrite}
  test "and restore brings it back as the Bluesky mode":
    check saveSession(SavedSession(brokerToken: "durable", handle: "alice.uk",
                                   nick: "alice"))
    restore()
    check app.brokerToken == "durable"
    check app.authMode == amBluesky
    check app.formHandle == "alice.uk"
    check app.formNick == "alice"

suite "the rooms file":
  setup: clean()

  proc saved(): seq[SavedRoom] =
    var rooms: OrderedTable[string, Room]
    for (name, accessed, id, at) in [("#a", 100'i64, "m1", 900'i64),
                                     ("#b", 300'i64, "m2", 800'i64),
                                     ("carol", 200'i64, "", 0'i64)]:
      var r = initRoom(name)
      r.accessed = accessed
      r.lastReadId = id
      r.lastReadAt = at
      r.messages = @[Message(id: "x", frm: "bob", text: "hi", at: 1000)]
      rooms[name] = r
    check saveRooms(rooms)
    loadRooms()

  test "keeps the name and the marker, and not the messages":
    # The list is the part worth keeping; the lines in it come from the
    # server, and a client that saved them would be a second copy to go
    # stale.
    let rs = saved()
    check rs.len == 3
    check rs[0].name == "#a"
    check rs[0].lastReadId == "m1"
    check rs[0].lastReadAt == 900

  test "restore brings them back empty, unjoined, with their markers":
    discard saved()
    restore()
    check app.rooms.len == 3
    check app.rooms["#a"].messages.len == 0
    check not app.rooms["#a"].joined
    check app.rooms["#a"].lastReadId == "m1"
    check app.rooms["#a"].accessed == 100
    check app.rooms["#b"].accessed == 300

  test "and the most recently used is still top of the list":
    discard saved()
    restore()
    check channelList(app.rooms, "")[0].name == "#b"

  test "a record with no marker is caught up, not unread from the start":
    # An older frq's file, or one that lost it. The alternative announces a
    # hundred lines the reader has already seen.
    discard saved()
    restore()
    let before = nowMs()
    check app.rooms["carol"].lastReadAt >= before - 5000
    check app.rooms["carol"].lastReadAt > 0

  test "a room the reader has closed stays closed":
    discard saved()
    restore()
    dispatch(%*{"id": "room.leave:#a"})
    app = initState()
    restore()
    check not app.rooms.hasKey("#a")
    check app.rooms.hasKey("#b")

suite "the prefs file":
  setup: clean()
  test "the three display toggles outlive the run":
    restore()
    let wasJoinPart = app.hideJoinPart
    dispatch(%*{"id": "join-part.toggle"})
    dispatch(%*{"id": "users.toggle"})
    app = initState()
    restore()
    check app.hideJoinPart == not wasJoinPart
    check app.showUsers
  test "the overview is not one of them":
    # It is a way of looking at the moment you are in rather than a
    # preference, and reopening into it would answer a question nobody asked
    # twice.
    restore()
    dispatch(%*{"id": "overview.toggle"})
    app = initState()
    restore()
    check not app.overview
  test "and a prefs file that is not there is a first run, not an error":
    check loadPrefs().len == 0
    restore()
    check not app.hideJoinPart
