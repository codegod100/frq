## What this client keeps on disk between runs.
##
## From `common/frq/store.cljc`. The Clojure writes EDN through the `frq.io`
## seam because ClojureDart had no portable filesystem; Nim has one, so the
## seam is gone and the format is JSON — nothing else reads these files, and a
## format with a parser in the standard library is one less thing to get wrong.
##
## Every read treats a file that will not parse as absent. A stale credential
## is not worth an error at startup, and a room with a broken marker would
## count its whole history unread — which is worse than a room that starts
## over.

import std/[json, os, strutils, tables]
import frq/[model, trace]

type
  SavedSession* = object
    ## The durable half of a sign-in. The web-token beside it is single-use
    ## and deliberately not saved.
    brokerToken*, handle*, did*, nick*: string

  SavedRoom* = object
    ## A room and how much of it has been seen.
    name*: string
    accessed*: int64
    lastReadId*: string
    lastReadAt*: int64

proc configDir*(): string =
  ## Where this client's files go.
  ##
  ## `$XDG_CONFIG_HOME/frq`, or `~/.config/frq`. The Clojure asks the host
  ## through `frq.io` because Android has no HOME to be relative to; this path
  ## is the desktop's, and Android will want its own answer when the APK gets
  ## a Nim core.
  let xdg = getEnv("XDG_CONFIG_HOME")
  if xdg.len > 0: xdg / "frq" else: getHomeDir() / ".config" / "frq"

proc sessionFile*(): string = configDir() / "session.json"
proc roomsFile*(): string = configDir() / "rooms.json"
proc prefsFile*(): string = configDir() / "prefs.json"

proc readJson(path: string): JsonNode =
  ## The file as JSON, or nil where it is absent or will not parse.
  if not fileExists(path): return nil
  try:
    parseJson(readFile(path))
  except CatchableError as e:
    trace("store", "ignoring " & path & ": " & e.msg)
    nil

proc loadSession*(): (SavedSession, bool) =
  ## The saved session, and whether there was one.
  ##
  ## A session with no broker token is not a session: the token is the whole
  ## point of saving one, and the handle beside it is only there to say whose
  ## it is.
  let j = readJson(sessionFile())
  if j.isNil: return (SavedSession(), false)
  let s = SavedSession(brokerToken: j{"brokerToken"}.getStr(),
                       handle: j{"handle"}.getStr(),
                       did: j{"did"}.getStr(),
                       nick: j{"nick"}.getStr())
  (s, s.brokerToken.len > 0)

proc saveSession*(s: SavedSession): bool =
  ## Written so nobody else can read it — the broker token goes through here
  ## and nothing else does.
  try:
    createDir(configDir())
    let path = sessionFile()
    writeFile(path, $(%*{"brokerToken": s.brokerToken, "handle": s.handle,
                         "did": s.did, "nick": s.nick}))
    # Created first and restricted second, because there is no atomic
    # create-with-mode here — the window is small and the alternative is a
    # token written world-readable and never narrowed.
    path.setFilePermissions({fpUserRead, fpUserWrite})
    true
  except CatchableError as e:
    trace("store", "could not save the session: " & e.msg)
    false

proc clearSession*() =
  ## A token the broker no longer honours is dropped rather than replayed on
  ## every Connect.
  try:
    removeFile(sessionFile())
  except CatchableError:
    discard

proc loadRooms*(): seq[SavedRoom] =
  ## The rooms this client knows, most recently used first.
  ##
  ## This is the authority for what rooms exist. The server forgets them — it
  ## has told us we are in rooms we are not, and left out ones we are — so a
  ## room is gone when the reader closes it here and not before.
  let j = readJson(roomsFile())
  if j.isNil or j.kind != JArray: return
  for r in j:
    let name = r{"name"}.getStr()
    if name.len == 0: continue
    result.add SavedRoom(name: name,
                         accessed: r{"accessed"}.getBiggestInt(),
                         lastReadId: r{"lastReadId"}.getStr(),
                         lastReadAt: r{"lastReadAt"}.getBiggestInt())

proc saveRooms*(rooms: OrderedTable[string, Room]): bool =
  ## The marker goes with the name, which is the point of saving at all: a
  ## phone that comes back to a hundred lines it has already read is a phone
  ## that kept the names and lost the markers.
  try:
    createDir(configDir())
    var arr = newJArray()
    for name, r in rooms:
      arr.add %*{"name": name, "accessed": r.accessed,
                 "lastReadId": r.lastReadId, "lastReadAt": r.lastReadAt}
    writeFile(roomsFile(), $arr)
    true
  except CatchableError as e:
    trace("store", "could not save the rooms: " & e.msg)
    false

proc loadPrefs*(): Table[string, bool] =
  let j = readJson(prefsFile())
  if j.isNil or j.kind != JObject: return
  for k, v in j:
    if v.kind == JBool: result[k] = v.getBool()

proc savePrefs*(prefs: Table[string, bool]): bool =
  try:
    createDir(configDir())
    var o = newJObject()
    for k, v in prefs: o[k] = %v
    writeFile(prefsFile(), $o)
    true
  except CatchableError:
    false
