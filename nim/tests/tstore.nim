## What survives a restart. Every case runs against a real directory under a
## temporary XDG_CONFIG_HOME, because the thing being tested is files.

import std/[os, tables, unittest]
import frq/[store, model]

template withTempConfig(body: untyped) =
  let dir = getTempDir() / "frq-test-store-" & $getCurrentProcessId()
  removeDir(dir)
  createDir(dir)
  putEnv("XDG_CONFIG_HOME", dir)
  defer:
    delEnv("XDG_CONFIG_HOME")
    removeDir(dir)
  body

suite "the session":
  test "absent when nothing was saved":
    withTempConfig:
      check loadSession()[1] == false

  test "round-trips":
    withTempConfig:
      check saveSession(SavedSession(brokerToken: "tok", handle: "alice",
                                     did: "did:plc:x", nick: "alice"))
      let (s, ok) = loadSession()
      check ok
      check s.brokerToken == "tok"
      check s.handle == "alice"
      check s.did == "did:plc:x"

  test "one with no broker token is not a session":
    # The token is the whole point of saving one.
    withTempConfig:
      check saveSession(SavedSession(handle: "alice"))
      check loadSession()[1] == false

  test "a file that will not parse is treated as absent":
    # A stale credential is not worth an error at startup.
    withTempConfig:
      createDir(configDir())
      writeFile(sessionFile(), "{ this is not json")
      check loadSession()[1] == false

  test "is written so nobody else can read it":
    withTempConfig:
      check saveSession(SavedSession(brokerToken: "tok"))
      let perms = getFilePermissions(sessionFile())
      check fpGroupRead notin perms
      check fpOthersRead notin perms

  test "clearing it leaves nothing behind":
    withTempConfig:
      check saveSession(SavedSession(brokerToken: "tok"))
      clearSession()
      check loadSession()[1] == false

  test "clearing one that is not there is not an error":
    withTempConfig:
      clearSession()

suite "the rooms":
  test "none when nothing was saved":
    withTempConfig:
      check loadRooms().len == 0

  test "round-trip, with the markers":
    # A phone that kept the names and lost the markers comes back to a
    # hundred lines it has already read.
    withTempConfig:
      var rooms = initOrderedTable[string, Room]()
      var a = initRoom("#one")
      a.accessed = 5
      a.lastReadId = "m1"
      a.lastReadAt = 1234
      rooms["#one"] = a
      rooms["#two"] = initRoom("#two")
      check saveRooms(rooms)

      let got = loadRooms()
      check got.len == 2
      check got[0].name == "#one"
      check got[0].accessed == 5
      check got[0].lastReadId == "m1"
      check got[0].lastReadAt == 1234

  test "order is kept — most recently used first is the file's own order":
    withTempConfig:
      var rooms = initOrderedTable[string, Room]()
      for n in ["#c", "#a", "#b"]: rooms[n] = initRoom(n)
      check saveRooms(rooms)
      check loadRooms().len == 3
      check loadRooms()[0].name == "#c"

  test "a record with no name is dropped rather than defaulted":
    withTempConfig:
      createDir(configDir())
      writeFile(roomsFile(), """[{"name":"#ok"},{"accessed":3}]""")
      let got = loadRooms()
      check got.len == 1
      check got[0].name == "#ok"

  test "a file that will not parse is no rooms, not an error":
    withTempConfig:
      createDir(configDir())
      writeFile(roomsFile(), "not json at all")
      check loadRooms().len == 0

suite "the preferences":
  test "round-trip":
    withTempConfig:
      check savePrefs({"hideJoinPart": true, "showUsers": false}.toTable)
      let got = loadPrefs()
      check got["hideJoinPart"] == true
      check got["showUsers"] == false

  test "absent is empty":
    withTempConfig:
      check loadPrefs().len == 0
