## What this client keeps between visits, in a browser.
##
## `localStorage` where the desktop has `$XDG_CONFIG_HOME/frq`. The same three
## files, the same JSON in them, under keys named for what they were: a reader
## who moves between the two does not carry their rooms across, but a reader
## who reloads the page keeps them.
##
## The desktop writes the session file with mode 600 and says why.
## `localStorage` has no such thing — it is readable by any script this origin
## runs — so the broker token is as safe as the page is, and no safer.

import std/[json, tables]
import frq/[model, trace]

type
  SavedSession* = object
    brokerToken*, handle*, did*, nick*: string

  SavedRoom* = object
    name*: string
    accessed*: int64
    lastReadId*: string
    lastReadAt*: int64

{.emit: """
function frqStoreGet(k) {
  try { return window.localStorage.getItem(k) || ""; } catch (e) { return ""; }
}
function frqStoreSet(k, v) {
  try { window.localStorage.setItem(k, v); return true; } catch (e) { return false; }
}
function frqStoreDel(k) {
  try { window.localStorage.removeItem(k); } catch (e) {}
}
""".}

proc getItem(key: cstring): cstring {.importc: "frqStoreGet".}
proc setItem(key, value: cstring): bool {.importc: "frqStoreSet".}
proc delItem(key: cstring) {.importc: "frqStoreDel".}

const
  sessionKey = "frq.session"
  roomsKey = "frq.rooms"
  prefsKey = "frq.prefs"

proc readJson(key: string): JsonNode =
  ## Absent and unparseable are the same answer here as on the desktop: a
  ## stale credential is not worth an error on load.
  let raw = $getItem(key.cstring)
  if raw.len == 0: return nil
  try: parseJson(raw)
  except CatchableError as e:
    trace("store", "ignoring " & key & ": " & e.msg)
    nil

proc loadSession*(): (SavedSession, bool) =
  let j = readJson(sessionKey)
  if j.isNil: return (SavedSession(), false)
  let s = SavedSession(brokerToken: j{"brokerToken"}.getStr(),
                       handle: j{"handle"}.getStr(),
                       did: j{"did"}.getStr(),
                       nick: j{"nick"}.getStr())
  (s, s.brokerToken.len > 0)

proc saveSession*(s: SavedSession): bool =
  setItem(sessionKey.cstring,
          ($(%*{"brokerToken": s.brokerToken, "handle": s.handle,
                "did": s.did, "nick": s.nick})).cstring)

proc clearSession*() = delItem(sessionKey.cstring)

proc loadRooms*(): seq[SavedRoom] =
  let j = readJson(roomsKey)
  if j.isNil or j.kind != JArray: return
  for r in j:
    let name = r{"name"}.getStr()
    if name.len == 0: continue
    result.add SavedRoom(name: name,
                         accessed: r{"accessed"}.getBiggestInt(),
                         lastReadId: r{"lastReadId"}.getStr(),
                         lastReadAt: r{"lastReadAt"}.getBiggestInt())

proc saveRooms*(rooms: OrderedTable[string, Room]): bool =
  var arr = newJArray()
  for name, r in rooms:
    arr.add %*{"name": name, "accessed": r.accessed,
               "lastReadId": r.lastReadId, "lastReadAt": r.lastReadAt}
  setItem(roomsKey.cstring, ($arr).cstring)

proc loadPrefs*(): Table[string, bool] =
  let j = readJson(prefsKey)
  if j.isNil or j.kind != JObject: return
  for k, v in j:
    if v.kind == JBool: result[k] = v.getBool()

proc savePrefs*(prefs: Table[string, bool]): bool =
  var o = newJObject()
  for k, v in prefs: o[k] = %v
  setItem(prefsKey.cstring, ($o).cstring)
