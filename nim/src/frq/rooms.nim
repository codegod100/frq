## The conversation list, and the read marker under it.
##
## Transcribed from `common/frq/rooms.cljc`. Pure functions over the state —
## everything here is a question about rooms rather than a change to one, with
## the two exceptions (`markRead`, `ensureRoom`) that are named for being
## changes.
##
## The marker is the part to read carefully. Unread is *derived* from it and
## never counted, because a count cannot survive what the server does: a JOIN
## replays the backlog and CHATHISTORY replays it again, and every line would
## tick a counter a second time. Against a marker a replayed line is simply
## older than it and counts for nothing.

import std/[algorithm, sequtils, strutils, tables]
import frq/[model, clock]

const
  overviewLimit* = 100
    ## How many lines the overview strip holds in all.

  freshRoomGraceMs* = 60_000'i64
    ## How far back a room nobody has seen before counts as already read.
    ##
    ## A room joined for the first time replays its whole history, and none of
    ## that is news — the reader was not away for it, they were not here. So a
    ## new buffer starts caught up rather than at the beginning, or joining a
    ## busy channel announces a hundred unread posts from before you arrived.
    ##
    ## A minute ago rather than this instant, because a live line is stamped
    ## by the server and this by our clock: the two disagree by whatever the
    ## skew is, and a live message stamped a few seconds behind us would land
    ## under the marker and never be counted. A minute is more skew than there
    ## will be and far less than the age of any backlog. What it costs is that
    ## a message sent in the minute before you joined counts as unread, which
    ## is the harmless direction.

func lastPreview*(ch: Room): string =
  if ch.messages.len == 0: "No messages yet"
  else:
    let m = ch.messages[^1]
    m.frm & ": " & m.text

func channelList*(channels: OrderedTable[string, Room], search: string): seq[Room] =
  ## Buffers most recently opened first, filtered by the search box.
  ##
  ## A conversation list is read from the top, and the one you were just in is
  ## the one you are most likely to want again. Buffers never opened — a DM
  ## that arrived, a channel someone mentioned — sort under those by name
  ## rather than jumping the queue.
  let q = search.strip().toLowerAscii
  for _, ch in channels:
    if q.len == 0 or ch.name.toLowerAscii.contains(q):
      result.add ch
  result.sort(proc (a, b: Room): int =
    # Descending by `accessed`, then ascending by name — the juxt in the
    # Clojure, which negates the first key and leaves the second alone.
    if a.accessed != b.accessed:
      cmp(b.accessed, a.accessed)
    else:
      cmp(a.name, b.name))

func lastVisited*(channels: OrderedTable[string, Room]): string =
  ## The room the reader had open when they last put the client down, or "".
  ##
  ## `accessed` is stamped by `openRoom` and saved beside the name, so the
  ## largest one is the last room opened — the same key `channelList` sorts
  ## by, which is why this always agrees with the top of that list.
  ##
  ## Zero is never-opened rather than long-ago: a channel the server put us
  ## in, or a DM that arrived while we were reading something else. A list
  ## with nothing but those has no last room, and the overview is the honest
  ## answer for a reader who has not yet been anywhere.
  var best: int64 = 0
  for _, ch in channels:
    if ch.accessed > best:
      best = ch.accessed
      result = ch.name

func mine*(m: Message, me: string): bool =
  ## Whether we are the one who said this.
  ##
  ## Nick against nick, which is what the server itself falls back to for an
  ## account with no DID — and an edit it would refuse is one not worth
  ## offering. A system line is nobody's to rewrite.
  (not m.system) and m.frm.len > 0 and
    m.frm.toLowerAscii == me.toLowerAscii

func seenMessage*(msgs: seq[Message], id, frm, text, me: string): bool =
  ## Whether this buffer already holds the line that has just arrived.
  ##
  ## The server hands the same message over more than once: a JOIN replays the
  ## backlog, CHATHISTORY replays it again, and a line can have arrived live
  ## before either. The msgid survives every revision, so holding the copy we
  ## have is what keeps a rejoin from doubling the buffer.
  ##
  ## Sometimes a line is replayed with no tags at all — no msgid to know it by
  ## and no time to place it. That line has no identity, so left alone it
  ## arrives new on every rejoin, appended again and stamped now, which is a
  ## room that can never be finished reading. What it does have is a sender
  ## and words, which for an untagged line is identity enough. The cost is
  ## that the same person saying the same thing twice — both untagged — shows
  ## once. Ours and the system's are left out of it: a second "ok" from this
  ## client, or a second "alice joined", is a real event rather than a replay.
  if id.len > 0:
    for m in msgs:
      if m.id == id: return true
    false
  else:
    if frm == "*" or frm.toLowerAscii == me.toLowerAscii:
      return false
    for m in msgs:
      if m.id.len == 0 and m.frm == frm and m.text == text: return true
    false

func roundRobin(colls: seq[seq[Message]]): seq[Message] =
  ## The colls' firsts, then their seconds, and so on until they are spent.
  ##
  ## This is how the overview stays about every room while still being a fixed
  ## number of lines. Taking the newest hundred outright would be the strip
  ## answering about whichever room is busiest — which is the one you can
  ## already see. A turn each means a room that said one thing all day is in
  ## the first handful, beside the room that has said a hundred.
  var live = colls.filterIt(it.len > 0)
  var i = 0
  while live.len > 0:
    var next: seq[seq[Message]]
    for c in live:
      if i < c.len:
        result.add c[i]
        next.add c
    if next.len == 0: break
    live = next
    i += 1

func recentEverywhere*(channels: OrderedTable[string, Room],
                       current: string): seq[Message] =
  ## The newest lines from every buffer at once, oldest first, and at most
  ## `overviewLimit` of them — a turn to each room until they run out.
  ##
  ## Bounded per room before anything else, so the cost is the number of rooms
  ## rather than the length of their backlogs: a channel with a week of
  ## history must not make this the most expensive thing on the screen.
  ##
  ## Joins, parts and the system's own chatter are left out — they are the
  ## noise this strip would drown in. So is the room being read: it is on the
  ## screen already, in full, directly above, and what the strip is for is the
  ## rooms you are not looking at.
  var colls: seq[seq[Message]]
  for name, ch in channels:
    if name == current: continue
    var said = ch.messages.filterIt(not it.system)
    for i in 0 ..< said.len: said[i].room = name
    if said.len > overviewLimit:
      said = said[^overviewLimit .. ^1]
    if said.len == 0: continue
    colls.add said.reversed          # newest first, the order a turn needs
  result = roundRobin(colls)
  if result.len > overviewLimit:
    result = result[0 ..< overviewLimit]
  # Oldest at the top, the way a conversation runs, now that the strip
  # scrolls: the newest is at the bottom where the eye finishes, and where
  # it is in every backlog on the screen. It read newest-first while nothing
  # here scrolled, when the top was all there was and the bottom was
  # wherever the list happened to be cut off.
  #
  # The turn-taking above is untouched, and the distinction matters: it
  # decides *which* lines are here -- the newest from each room, a turn each
  # -- and this decides only where they sit.
  result.sort(proc (a, b: Message): int = cmp(a.at, b.at))

func afterMarker*(ch: Room): seq[Message] =
  ## The messages the reader has not seen: everything after the read marker.
  ##
  ## By id where the marked message is still held, and by time otherwise. The
  ## id is the exact answer — a msgid survives every revision, so it names the
  ## same line however often the server replays it — and the timestamp is what
  ## answers when the marked line has fallen off the end of the buffer or was
  ## never in this run's copy of it.
  if ch.lastReadId.len > 0:
    for i, m in ch.messages:
      if m.id == ch.lastReadId:
        return if i + 1 <= ch.messages.high: ch.messages[i + 1 .. ^1] else: @[]
  ch.messages.filterIt(it.at > ch.lastReadAt)

func adoptEcho*(r: var Room, frm, text, id: string, at: int64,
                account: string): bool =
  ## Our own line, coming back from the server, folded onto the copy we
  ## already showed.
  ##
  ## `echo-message` is negotiated, so every line this client sends arrives
  ## again with a msgid on it — which is the point of asking for the cap, and
  ## is the only way this client learns what the server called something it
  ## said. Appending it is what showed every sent message twice.
  ##
  ## `seenMessage` deliberately will not catch this: it refuses to treat our
  ## own untagged lines as replays, because a second "ok" from this client is
  ## a real event rather than an echo. The difference is `pending` — a line we
  ## sent and have not seen back yet — and only a pending one is adopted.
  ##
  ## Oldest first, because the server echoes in the order it received, so the
  ## same text sent twice adopts onto the earlier copy.
  for i in 0 ..< r.messages.len:
    if r.messages[i].pending and r.messages[i].id.len == 0 and
       r.messages[i].frm == frm and r.messages[i].text == text:
      r.messages[i].id = id
      r.messages[i].pending = false
      if at > 0: r.messages[i].at = at
      if account.len > 0: r.messages[i].account = account
      return true
  false

func mentionsMe*(m: Message, me: string): bool =
  ## Whether a line is addressed at the reader by name. Our own lines do not
  ## count — saying your own nick is not being called.
  let me = me.strip()
  me.len > 0 and m.frm != me and m.text.toLowerAscii.contains(me.toLowerAscii)

func recount*(ch: Room, me: string): Room =
  ## Answer what the marker says: how many lines are unseen, and whether any
  ## of them names the reader.
  ##
  ## Joins, parts and "Joined #room" are the room talking about itself, not
  ## somebody talking in it. They arrive stamped now, so counted, every room
  ## you are a member of sits at one unread from the moment it opens, saying
  ## only that you joined it. The marker still moves past them: they are read,
  ## they are just never what made a room worth looking at.
  result = ch
  let fresh = ch.afterMarker.filterIt(not it.system)
  result.unread = fresh.len
  result.mention = fresh.anyIt(it.mentionsMe(me))

func markRead*(ch: Room): Room =
  ## Move the marker to the newest line this buffer holds. Both halves: the id
  ## for as long as that line is here, and its time for after it is gone.
  ##
  ## The time only ever goes forward. A backlog can arrive after the reader
  ## has already read past it, and taking the last line's time unconditionally
  ## would walk the marker backwards and re-unread what was read.
  result = ch
  result.unread = 0
  result.mention = false
  if ch.messages.len > 0:
    let newest = ch.messages[^1]
    result.lastReadId = newest.id
    result.lastReadAt = max(ch.lastReadAt, newest.at)

proc ensureRoom*(channels: var OrderedTable[string, Room], name: string) =
  ## Make sure a buffer exists, started caught up rather than at the
  ## beginning — see `freshRoomGraceMs`.
  if channels.hasKey(name): return
  var ch = initRoom(name)
  ch.lastReadAt = max(0'i64, nowMs() - freshRoomGraceMs)
  channels[name] = ch
