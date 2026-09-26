## A `draft/multiline` batch, put back together into the one message it is.
##
## freeq sends a message with line breaks in it as a batch: an opener that
## carries the message's tags (msgid, time, account, signature), one PRIVMSG
## per line carrying nothing but `batch=<id>`, and a closer. It does this in a
## CHATHISTORY replay as well, nested inside the history batch.
##
## Without the capability it sends the fallback instead — the same lines with
## the tags on the first only — and a reader that takes each line on its own
## gets rows with no msgid (so no reply or react), no account (so no face) and
## no time. The last is the worst of them: an untimed line is stamped with the
## moment it arrived, so a replayed paragraph sorts below everything and sits
## at the bottom of the room as though it were the newest thing said.
##
## So the client asks for the batch, and this hands the reducer one PRIVMSG
## with the opener's tags and the lines joined, as though it had come as one.
## Everything else passes straight through.

import std/[strutils, tables]
import frq/ircparse

func hasTag*(tags, key: string): bool =
  ## Whether a tag is there at all. `tagValue` reads an empty value as absent,
  ## which is right for a value and wrong for a flag: `draft/multiline-concat`
  ## and `+freeq.at/multiline` are nothing but their names.
  for pair in tags.split(';'):
    let eq = pair.find('=')
    if (if eq < 0: pair else: pair[0 ..< eq]) == key: return true

type
  Pending = object
    opener: IrcLine
    target: string
    body: string
    lines: int

  Assembler* = object
    open: Table[string, Pending]

proc feed*(a: var Assembler, p: IrcLine): seq[IrcLine] =
  ## What the reducer should see for this line: nothing while a batch is
  ## being gathered, the whole message when it closes, and anything else as
  ## it came.
  if p.command == "BATCH" and p.params.len >= 1:
    let id = p.params[0]
    if id.startsWith("+") and p.params.len >= 3 and
       p.params[1] == "draft/multiline":
      a.open[id[1 .. ^1]] = Pending(opener: p, target: p.params[2])
      return
    if id.startsWith("-") and a.open.hasKey(id[1 .. ^1]):
      let done = a.open[id[1 .. ^1]]
      a.open.del(id[1 .. ^1])
      var m = done.opener
      m.command = "PRIVMSG"
      m.params = @[done.target, done.body]
      return @[m]
  let (batch, inBatch) = tagValue(p.tags, "batch")
  if inBatch and a.open.hasKey(batch) and p.command in ["PRIVMSG", "NOTICE"] and
     p.params.len >= 2:
    var pending = a.open[batch]
    # A line marked concat continues the one before it — a long line the
    # sender had to cut — rather than starting a new one.
    if pending.lines > 0 and not hasTag(p.tags, "draft/multiline-concat"):
      pending.body.add '\n'
    pending.body.add p.params[^1]
    pending.lines.inc
    a.open[batch] = pending
    return
  # freeq's older form, still what a peer that predates the batch relays:
  # one line, with each break written as the two characters `\n`.
  if p.command in ["PRIVMSG", "NOTICE"] and p.params.len >= 2 and
     hasTag(p.tags, "+freeq.at/multiline"):
    var m = p
    m.params[^1] = m.params[^1].replace("\\n", "\n")
    return @[m]
  @[p]

proc reset*(a: var Assembler) =
  ## A new connection: a batch the old one left open is never closing.
  a.open.clear()
