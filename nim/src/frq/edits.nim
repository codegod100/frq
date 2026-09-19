## A revision, folded into the buffer it belongs to.
##
## From `common/frq/edits.cljc`.

import std/[strutils, tables]
import model

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
