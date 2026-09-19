## Emoji pills: the tally, and folding one change into a buffer.
##
## From `common/frq/reactions.cljc`. The tally is a seq of `Reaction` rather
## than a map so the pills keep their order — a map would have thrown away
## the order they are drawn in, and the Clojure gets away with it only because
## its map happens to preserve insertion for small maps.

import std/[strutils, tables]
import frq/[model]

func parseTally*(encoded: string): seq[Reaction] =
  ## The server's tally of what is already on a message, as
  ## `emoji:nick,nick;emoji:nick` — what CHATHISTORY sends so reactions
  ## survive a reconnect rather than starting empty every time the app opens.
  if encoded.len == 0: return
  for part in encoded.split(';'):
    let i = part.find(':')
    if i <= 0: continue
    let emoji = part[0 ..< i]
    let nicks = part[i + 1 .. ^1]
    if emoji.len == 0 or nicks.len == 0: continue
    var r = Reaction(emoji: emoji)
    for nk in nicks.split(','):
      if nk.strip().len > 0: r.nicks.add nk
    if r.nicks.len > 0: result.add r

func withReaction*(reactions: seq[Reaction], emoji, nick: string,
                   on: bool): seq[Reaction] =
  ## One nick's reaction added to or taken off a tally. An emoji nobody is
  ## left on goes away with them: an empty pill is a pill that says nothing.
  var found = false
  for r in reactions:
    if r.emoji != emoji:
      result.add r
      continue
    found = true
    var nicks: seq[string]
    if on:
      nicks = r.nicks
      if nick notin nicks: nicks.add nick
    else:
      for nk in r.nicks:
        if nk != nick: nicks.add nk
    if nicks.len > 0:
      result.add Reaction(emoji: emoji, nicks: nicks)
  if on and not found:
    result.add Reaction(emoji: emoji, nicks: @[nick])

func mine*(m: Message, emoji, nick: string): bool =
  ## Whether `nick` is already on that emoji — which is what makes a second
  ## press take it off rather than send the same reaction twice.
  for r in m.reactions:
    if r.emoji == emoji: return nick in r.nicks
  false

func countOf*(m: Message, emoji: string): int =
  for r in m.reactions:
    if r.emoji == emoji: return r.nicks.len
  0

proc updateReaction*(rooms: var OrderedTable[string, Room],
                     room, msgid, emoji, nick: string, on: bool) =
  ## One reaction folded into the buffer it belongs to.
  ##
  ## The message it names may not be there — a reaction on something older
  ## than the backlog we asked for — and then there is nothing to show it on,
  ## so nothing happens.
  ##
  ## Named the way a reply names one: somebody reacting to a line that has
  ## since been rewritten puts the emoji on the revision's msgid, which is a
  ## name the message answers to. See `model.answersTo`.
  if room.len == 0 or msgid.len == 0 or emoji.len == 0: return
  if not rooms.hasKey(room): return
  var r = rooms[room]
  for i in 0 ..< r.messages.len:
    if r.messages[i].answersTo(msgid):
      r.messages[i].reactions =
        r.messages[i].reactions.withReaction(emoji, nick, on)
  rooms[room] = r

func peerDid*(r: Room, me: string): string =
  ## The DID of whoever this DM buffer is with, from the last thing they said.
  ##
  ## Empty for a channel, and for a conversation where nobody with a DID has
  ## spoken — a signature over a DM needs both sides named, and there is
  ## nothing to name.
  if r.name.startsWith("#"): return ""
  for i in countdown(r.messages.high, 0):
    let m = r.messages[i]
    if m.frm != me and m.frm.len > 0:
      return m.frm
  ""
