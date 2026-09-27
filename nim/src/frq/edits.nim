## A revision, folded into the buffer it belongs to.
##
## From `common/frq/edits.cljc`.

import std/[strutils, tables]
import frq/[model, reactions]

type
  EditResult* = enum
    erApplied = "applied"
    erRefused = "refused"
      ## Not the sender's line to rewrite.
    erAbsent = "absent"
      ## No line here has that id — an edit of something older than the
      ## backlog we asked for. The one case the caller shows as a line of its
      ## own rather than losing what it says.

proc applyEdit*(rooms: var OrderedTable[string, Room],
                room, msgid, frm, text, revision: string): EditResult =
  ## Only the sender may rewrite their own line, so an edit whose nick is not
  ## the one on the message is dropped. The server checks authorship too, and
  ## a client that believed the wire alone would let a hostile relay put words
  ## in somebody else's mouth.
  ##
  ## `revision` is the msgid the server gave the edit itself, which joins
  ## `editIds` so a reply naming it still finds the line it belongs to.
  if room.len == 0 or msgid.len == 0: return erAbsent
  if not rooms.hasKey(room): return erAbsent
  var r = rooms[room]
  result = erAbsent
  for i in 0 ..< r.messages.len:
    if r.messages[i].id != msgid: continue
    if r.messages[i].frm.toLowerAscii != frm.toLowerAscii:
      result = erRefused
      continue
    r.messages[i].text = text
    r.messages[i].edited = true
    if revision.len > 0 and revision notin r.messages[i].editIds:
      r.messages[i].editIds.add revision
    result = erApplied
  rooms[room] = r

proc applyDelete*(rooms: var OrderedTable[string, Room],
                  room, msgid: string): bool =
  ## Take a line out of the buffer it was said in.
  ##
  ## freeq's delete is soft on its side — a `deleted_at` on the row — but
  ## what it means to a reader is that the line is gone: the server leaves it
  ## out of CHATHISTORY and out of a JOIN replay, so a buffer that kept it
  ## would be the only place it still existed, and only until a reconnect.
  ##
  ## Unlike `applyEdit` this does not check the nick, and the difference is
  ## in what the two relays could do. A forged edit puts words in somebody's
  ## mouth; a forged delete takes words away, and the server has already
  ## refused any delete whose actor was neither the author nor an op —
  ## `AUTHOR_MISMATCH`. Checking authorship here would only disagree with it
  ## in the one case it is right and we cannot see: an op clearing up. The
  ## line would sit on screen, deleted everywhere else.
  if room.len == 0 or msgid.len == 0: return false
  if not rooms.hasKey(room): return false
  var r = rooms[room]
  let i = r.indexById(msgid)
  if i < 0: return false
  r.messages.delete(i)
  rooms[room] = r
  true

type
  PendingEdit* = object
    ## An edit that is on this screen and not yet on the server's, and the
    ## wording it replaced.
    ##
    ## An edit is shown the moment it is sent, so a refusal — a signature the
    ## server cannot check, a line it has no record of — would otherwise leave
    ## the new wording here and the old one everywhere else, with nothing to
    ## say so. This is what puts it back.
    room*, id*: string
    text*: string
    edited*: bool

proc beforeEdit*(rooms: OrderedTable[string, Room],
                 room, msgid: string): (PendingEdit, bool) =
  ## The line as it stands, taken before an edit rewrites it.
  if not rooms.hasKey(room): return
  for m in rooms[room].messages:
    if m.id == msgid:
      return (PendingEdit(room: room, id: msgid, text: m.text,
                          edited: m.edited), true)

proc restoreEdit*(rooms: var OrderedTable[string, Room],
                  p: PendingEdit): bool =
  ## Put a refused edit's line back the way it was.
  if not rooms.hasKey(p.room): return false
  var r = rooms[p.room]
  for i in 0 ..< r.messages.len:
    if r.messages[i].id != p.id: continue
    r.messages[i].text = p.text
    r.messages[i].edited = p.edited
    result = true
  rooms[p.room] = r

type
  MutationKind* = enum
    mkDelete = "delete"
    mkReact = "react"

  PendingMutation* = object
    ## A delete or a reaction that is on this screen and not yet known to be
    ## on the server's, with what it takes to undo it.
    ##
    ## freeq never echoes a delete to the one who sent it, and a reaction's
    ## echo says nothing a refusal would not also leave unsaid, so neither has
    ## an "accepted" to wait for. What there is instead is order: the server
    ## answers a connection's lines one at a time, so a `PING` sent after the
    ## mutation comes back after any `FAIL` for it. `token` is that PING's.
    token*: string
    room*, id*: string
    case kind*: MutationKind
    of mkDelete:
      line*: Message   ## the line as it was, to put back
      at*: int         ## and where it stood
    of mkReact:
      emoji*, nick*: string
      on*: bool        ## what was asked: added, or taken away

proc beforeDelete*(rooms: OrderedTable[string, Room], room, msgid,
                   token: string): (PendingMutation, bool) =
  ## The line a delete is about to take, and where it was.
  if not rooms.hasKey(room): return
  let i = rooms[room].indexById(msgid)
  if i < 0: return
  (PendingMutation(kind: mkDelete, token: token, room: room, id: msgid,
                   line: rooms[room].messages[i], at: i), true)

proc undoMutation*(rooms: var OrderedTable[string, Room],
                   p: PendingMutation): bool =
  ## Take back a delete or a reaction the server refused.
  if not rooms.hasKey(p.room): return false
  case p.kind
  of mkDelete:
    var r = rooms[p.room]
    # Somebody else may have put it back first — a replay, a reconnect.
    if r.indexById(p.id) >= 0: return false
    r.messages.insert(p.line, min(p.at, r.messages.len))
    rooms[p.room] = r
    true
  of mkReact:
    rooms.updateReaction(p.room, p.id, p.emoji, p.nick, not p.on)
    true
