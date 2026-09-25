## The conversation.
##
## Transcribed from `common/frq/screens/chat.cljc`, which is the biggest
## screen and the one the port is really about. The structure is kept: a
## message is a sender's row and a body under it, the actions ride the
## sender's row, and the day heading sits between the lines rather than on
## them.
##
## What is *not* here is the call wall and its controls. They are ~110 lines
## of the original and they drive `frq.actions/start-call!`, which no target
## has installed since the MoQ media plane was retired with the jolt half —
## dead buttons in ClojureDart and dead buttons here. When Flutter's camera
## and audio plugins arrive this is the file they come back to.

import std/[algorithm, json, strutils, tables]
import std/options
import frq/[ui, cells, model, clock, reactions, textruns, members,
           glyphs, emoji, rooms, profile]
import frq/links as lk
from frq/screens/connect import errorNote
from frq/screens/frame import tabBar

const
  faceSize = 32
  pillSize = 20
  chipGap = 4
  overviewLines* = 40


  sidePanelWidth = 150
    ## What a strip beside the backlog takes. Wide enough for a room name or
    ## a nick, narrow enough that the conversation is still the pane.

func actionChips(m: Message, mine: bool): Node =
  ## Answering and reacting, on the sender's row above the message.
  ##
  ## Both are things done *to* a message rather than parts of it, so they ride
  ## the sender's row against its right edge, at the size a reaction is. In
  ## the line with the text they took width off every line under them and
  ## wrapped a message that had the room to sit on one.
  ##
  ## Only our own lines carry the edit chip: the server refuses an edit of
  ## somebody else's, and a chip that always fails is a chip that lies.
  ##
  ## The glyphs are all emoji-presentation codepoints, and that is a
  ## constraint rather than a preference. `✏️` is U+270F plus a variation
  ## selector *asking* for emoji presentation, and the ask is not binding:
  ## some font claims the bare U+270F and draws the monochrome pencil the
  ## text era had. On a desktop that font is DejaVu Sans, which naming the
  ## colour face gets around; in a browser CanvasKit has no such face to name
  ## — naming one gives notdef boxes — so the only reliable answer is a
  ## codepoint no text font claims. Hence 📝 where ✏️ was, and 💬 where ↩️
  ## was: both are emoji-only, and both come out in colour everywhere.
  result = n("hbox", %*{"key": "actions", "align": "end", "spacing": chipGap}, @[
    n("reaction", %*{"key": "react", "emoji": "🙂", "size": pillSize,
                     "onClick": "react.open:" & rowId(m)}),
    n("reaction", %*{"key": "reply", "emoji": "💬", "size": pillSize,
                     "onClick": "reply.to:" & rowId(m)})])
  if mine:
    result.children.add n("reaction",
      %*{"key": "edit", "emoji": "📝", "size": pillSize,
         "onClick": "edit.start:" & rowId(m)})

func reactionRow(m: Message, me: string): Node =
  ## What people have put on a message, under it.
  ##
  ## A pill carries its count and toggles: clicking one you are already on
  ## takes yours off, which is the same gesture that put it there. `reaction`
  ## rather than a button with the emoji as its label — the renderer draws a
  ## `reaction` in the colour emoji font, where a label gets whatever ordinary
  ## fallback finds — see `actionChips` on why the glyphs here avoid the
  ## variation-selector kind entirely.
  result = n("hbox", %*{"key": "pills", "spacing": chipGap})
  var emojis: seq[string]
  for r in m.reactions: emojis.add r.emoji
  emojis.sort()
  for e in emojis:
    result.children.add reaction(e, m.countOf(e), m.mine(e, me),
                                 "react.toggle:" & rowId(m) & ":" & e)

func replyChip(target: Message): Node =
  ## A chip above a reply, quoting what it answers, and a click that goes
  ## there.
  n("hbox", %*{"key": "reply-chip", "spacing": 6}, @[
    dimLabel("↩ " & target.frm & ": " & summarise(target.text, 36)),
    button("→", "goto:" & rowId(target))])

func runNodes(m: Message): Node =
  ## The words, as one inline row — a paragraph. Stacking gave every link a
  ## line of its own, and a plain wrapping row measures each label against the
  ## row's width rather than the column's, which is what drags long URLs off
  ## the left edge.
  result = paragraph()
  result.props["key"] = %"runs"
  for r in textRuns(m.text):
    case r.kind
    of rkText: result.children.add text(r.value)
    of rkLink: result.children.add link(r.value, r.value)
    of rkStrong: result.children.add n("strong", %*{"text": r.value})
    of rkEmphasis: result.children.add n("emphasis", %*{"text": r.value})
    of rkCode: result.children.add n("code", %*{"text": r.value})

proc previewCard(url: string): Node =
  ## What is at the end of a link, under the line that pasted it.
  ##
  ## Nothing while it is being fetched and nothing where it failed: a card
  ## that says "loading" is a row that appears, changes height and
  ## disappears again in every message of a backlog, and a card that says
  ## "no preview" is a card about this client rather than about the link.
  ## The link itself is in the text either way, so the failure mode is the
  ## message as it reads without any of this.
  ##
  ## The title is the control rather than the whole card: `link` is the one
  ## tag that opens a URL, and a card that took the press would need the
  ## renderer to learn a second way — which is a change on both sides of a
  ## boundary that is supposed to hold.
  let (p, has) = lk.lookup(url)
  if not has or p.status != lk.lsReady: return nil
  result = card(%*{"key": "preview", "spacing": 2})
  if p.image.len > 0:
    result.children.add image(p.image, maxWidth = 320, maxHeight = 160,
                              onClick = "lightbox:" & p.image)
  let site = if p.siteName.len > 0: p.siteName else: lk.domainOf(url)
  if site.len > 0:
    result.children.add dimLabel(site)
  if p.title.len > 0:
    result.children.add link(p.title, url)
  if p.description.len > 0:
    result.children.add text(p.description, lines = 2)

const pickerColumns = 8
  ## How wide the emoji grid is. Narrow enough to sit under a message on a
  ## phone without the compose bar leaving the screen.

proc emojiPicker(s: State): Node =
  ## The set to choose from, under the message it is for.
  ##
  ## A panel over the compose bar rather than a screen: what is being reacted
  ## to has to stay in sight, which is the whole reason a reaction is cheaper
  ## than typing.
  result = card(
    hbox(%*{"spacing": 8},
      entry("emoji-search", s.emojiSearch, "Search emoji",
            "emoji.search.change", width = 200),
      button("✕", "react.close")))

  # The groups, as a row of switches. Nothing selected is the popular row,
  # which is what the picker opens on.
  var groupRow = hbox(%*{"spacing": 4})
  groupRow.children.add button("Popular", "emoji.group:",
                               if s.emojiGroup.len == 0: "primary" else: "default")
  for g in groups:
    groupRow.children.add button(g, "emoji.group:" & g,
                                 if s.emojiGroup == g: "primary" else: "default")
  result.children.add groupRow

  # The grid. Capped, because the catalogue is 1,884 and a tree that carries
  # all of them across the boundary on every keystroke is a tree nobody can
  # type into.
  let shown = pickerEmoji(s.emojiSearch, s.emojiGroup)
  var grid = vbox(%*{"key": "grid", "spacing": 4})
  var row = hbox(%*{"spacing": 4})
  var n = 0
  for e in shown:
    if n >= pickerLimit: break
    row.children.add reaction(e.glyph, 0, false,
                              "react.pick:" & e.glyph)
    n += 1
    if n mod pickerColumns == 0:
      grid.children.add row
      row = hbox(%*{"spacing": 4})
  if row.children.len > 0: grid.children.add row
  if n == 0:
    grid.children.add dimLabel("Nothing matches that.")
  elif shown.len > pickerLimit:
    grid.children.add dimLabel("…and " & $(shown.len - pickerLimit) & " more — keep typing.")
  result.children.add grid

func taskHeadline(verb: string): (string, string, string) =
  ## The lifecycle word, glyph and visual register for a handoff event.
  ## These name states, not colours: Flutter maps them to this client's theme.
  case verb
  of "offer": ("📋", "offered", "new")
  of "accept": ("👍", "accepted", "active")
  of "decline": ("👎", "declined", "danger")
  of "claim": ("✋", "claimed", "active")
  of "progress": ("📌", "in progress", "active")
  of "complete": ("🎉", "completed", "success")
  of "fail": ("❌", "failed", "danger")
  of "cancel": ("🚫", "cancelled", "danger")
  else: ("📌", verb, "neutral")

proc taskCard(room: Room, m: Message, highlit: bool): Node =
  ## The visible companion of a typed FreeQ handoff event. The event itself is
  ## a TAGMSG; keeping its title and facts in this compact card makes the
  ## lifecycle scannable without pretending ordinary bot prose is structured.
  let task = m.task
  let (glyph, headline, tone) = taskHeadline(task.verb)
  result = n("task-card", %*{"key": "task-" & rowId(m), "glyph": glyph,
                             "headline": headline, "tone": tone,
                             "eventId": task.id, "time": clockTime(m.at),
                             "highlight": highlit}, @[])
  if task.title.len > 0: result.children.add text(task.title)
  var facts = vbox(%*{"key": "task-facts", "spacing": 2})
  for (name, value) in [("task id", task.taskId), ("event id", task.id),
                         ("kind", task.kind), ("verb", task.verb)]:
    if value.len > 0:
      facts.children.add hbox(%*{"spacing": 8}, dimLabel(name), text(value))
  if task.verb == "offer" or task.offeredTo.len > 0:
    facts.children.add hbox(%*{"spacing": 8}, dimLabel("offered to"),
                             label(if task.offeredTo.len > 0: task.offeredTo else: "anyone"))
  if task.caps.len > 0:
    facts.children.add hbox(%*{"spacing": 8}, dimLabel("skills required"),
                             label(task.caps))
  if task.note.len > 0:
    facts.children.add hbox(%*{"spacing": 8}, dimLabel("note"), text(task.note))
  if task.context.len > 0:
    facts.children.add hbox(%*{"spacing": 8}, dimLabel("context"),
                             link(task.context, task.context))
  if facts.children.len > 0: result.children.add facts

  var cards: seq[Message]
  for other in room.messages:
    if other.task.taskId == task.taskId and other.task.id.len > 0:
      cards.add other
  var here = -1
  for i, other in cards:
    if other.task.id == task.id:
      here = i
      break
  if here >= 0 and cards.len > 1:
    var footer = hbox(%*{"spacing": 8, "wrap": false})
    if here > 0: footer.children.add button("← prev", "goto:" & rowId(cards[here - 1]), "plain")
    footer.children.add spacer(0)
    if here < cards.high:
      footer.children.add n("button", %*{"label": "next →", "kind": "plain",
                                           "onClick": "goto:" & rowId(cards[here + 1]),
                                           "expand": true})
    result.children.add footer

proc messageBody(s: State, room: Room, m: Message, highlit: bool): Node =
  ## A message without its face: the sender's line, the words, and what hangs
  ## under them.
  var who = vbox(%*{"key": "who"})
  if m.system:
    if m.at > 0:
      who.children.add dimLabel(clockTime(m.at))
  else:
    # A face is a way in to who someone is, so it takes the press that opens
    # them — and so does the name beside it, since a name is the thing a
    # reader is actually looking at.
    # The `account` tag where the server sends one, and what WHO reported
    # for this nick where it does not — freeq is the second case.
    let senderActor = actorFor(
      if m.account.len > 0: m.account else: s.dids.getOrDefault(m.frm, ""),
      m.frm)
    let open = "profile.open:" & m.frm & ":" & senderActor
    # A row where there is room for one, a Wrap where there is not.
    #
    # The chips ride the right edge because the name takes the slack: it is
    # the row's one expanding child, drawn at the left of a box that grows,
    # so everything after it is carried to the far edge. On a phone there is
    # no slack to take — with the name shrunk to nothing, the face, the time
    # and three chips still ask for more than 360 points has — which is why
    # this was a Wrap to begin with, and why on a narrow window it still is,
    # putting the chips on a second line rather than off the edge.
    var row = hbox(%*{"spacing": 6, "wrap": not s.wide},
      # From the profile cache rather than the message: a face belongs to a
      # person, not to a line they said, and a profile that arrives after
      # their first message should appear on all of them.
      avatar(avatarFor(senderActor, m.frm), m.frm, size = faceSize,
             onClick = open),
      n("button", %*{"label": m.frm, "kind": "plain", "onClick": open,
                     "expand": s.wide}))
    if m.at > 0:
      row.children.add dimLabel(clockTime(m.at))
    if m.edited:
      row.children.add dimLabel("(edited)")
    if m.id.len > 0:
      row.children.add actionChips(m, m.frm == s.formNick)
    else:
      # A spacer where the chips would be, so a line with no msgid is a row of
      # the same shape rather than a row with a hole in it.
      row.children.add spacer(0)
    who.children.add row

  # The reply chip is in a wrapper that is always there, for the reason the
  # error note is: a child that comes and goes renumbers the row.
  var chip = vbox(%*{"key": "reply-chip"})
  if m.replyTo.len > 0:
    let target = room.messageById(m.replyTo)
    if target.isSome:
      chip.children.add replyChip(target.get)
    else:
      # Named but not held — a reply to something older than the backlog we
      # asked for. Said plainly rather than silently dropped.
      chip.children.add dimLabel("↩ (an earlier message)")

  var body = vbox(%*{"key": "text", "spacing": 2, "marginTop": 4},
    chip, runNodes(m))

  var images = vbox(%*{"key": "images", "spacing": 4})
  if m.imageUrl.len > 0:
    images.children.add image(m.imageUrl, maxWidth = 320, maxHeight = 240,
                              onClick = "lightbox:" & m.imageUrl)

  # What the link in the message turned out to be, where it has come back.
  var preview = vbox(%*{"key": "preview-row", "spacing": 4})
  if not m.system:
    let url = firstPreviewUrl(m.text)
    if url.len > 0:
      let cardNode = previewCard(url)
      if not cardNode.isNil: preview.children.add cardNode

  # The picker, under the message it is for and nowhere else.
  var picker = vbox(%*{"key": "picker", "marginBottom": 4})
  if s.reacting.has and s.reacting.id == rowId(m):
    picker.children.add emojiPicker(s)

  var pills = vbox(%*{"key": "reactions-row", "marginTop": 6})
  if m.id.len > 0 and not m.system and m.reactions.len > 0:
    pills.children.add reactionRow(m, s.formNick)

  # A card when the jump landed here, a plain box otherwise — the highlight is
  # how a reader finds the line they were sent to.
  if m.task.id.len > 0:
    return taskCard(room, m, highlit)
  # Only a typed handoff companion above is a task. The channel it was said in
  # is not a type: #tasks still contains ordinary conversation and bot prose.
  n(if highlit: "card" else: "vbox",
    %*{"key": (if highlit: "body-card" else: "body-plain"),
       "spacing": 2, "margin": 0, "task": false},
    @[who, body, picker, images, preview, pills])

proc messageRow(s: State, room: Room, i: int, m: Message): Node =
  ## One message: who said it, when, what you can do to it, and the words.
  ##
  ## Every line names its sender, rather than the first of a run only. A run
  ## collapsed to one heading reads well until you answer the fourth line of
  ## it, and then the line quoted back has no name on it; and the actions live
  ## on the sender's row, which a headerless line has nowhere to put.
  let rid = rowId(m)
  let highlit = rid.len > 0 and rid == s.highlight
  # Keyed by the message and not by its position. A line arriving, or the
  # join/part filter coming off, renumbers every row under it — and a key
  # that renumbers is a row the renderer tears down and builds again, taking
  # with it whatever state Flutter held for it. A live text selection is the
  # loudest thing that state has been.
  n("vbox", %*{"key": (if rid.len > 0: rid else: "row-" & $i),
               "spacing": 2, "margin": 0, "marginRight": 10,
               "marginTop": 10,
               "scrollHere": rid.len > 0 and rid == s.jumpTo},
    @[messageBody(s, room, m, highlit)])

func daySeparator(key, label0: string): Node =
  n("hbox", %*{"key": key, "spacing": 8}, @[separator(), dimLabel(label0)])

proc messageRows*(s: State, room: Room, messages: seq[Message]): seq[Node] =
  ## The messages, with a heading wherever the day changes.
  ##
  ## `room` is passed down rather than read from `s` where it is wanted, and
  ## that is not tidiness: `State.currentRoom` returns a Room **by value**, and
  ## a Room owns its whole backlog, so every call deep-copies every message in
  ## it. Resolving a reply that way — once per replying line, per render —
  ## was 100 × 500 message copies a frame in a busy room, ten times a second.
  ##
  ## A backlog can reach back weeks, and `11:04 AM` says nothing about which
  ## day it was. The heading is what makes the time above it mean something.
  # `prevDay` is carried rather than recomputed: asking `day()` for the
  # previous message repeated the work the previous iteration had already
  # done, doubling the zone lookups for the whole backlog.
  var prevDay = ""
  for i, m in messages:
    if m.at > 0:
      let d = day(m.at)
      if d != prevDay:
        result.add daySeparator("day-" & d, dayLabel(m.at))
      prevDay = d
    result.add messageRow(s, room, i, m)

proc visible(s: State, messages: seq[Message]): seq[Message] =
  ## The lines this reader wants to see. Comings and goings are the room
  ## talking about itself; a quiet room reads better with them and a busy one
  ## drowns in them, so it is the reader's call.
  for m in messages:
    if s.hideJoinPart and m.system: continue
    result.add m

proc overviewPane(s: State): Node =
  ## What is happening in every room but this one, oldest first.
  ##
  ## A turn to each room rather than the newest lines outright — see
  ## `rooms.recentEverywhere`. Taking the newest hundred would be the strip
  ## answering about whichever room is busiest, which is the one already on
  ## screen.
  # One card a line, and the card is the control.
  #
  # This was a single card holding rows of [room, sender, text, →]. In a
  # Wrap on a phone that is three lines an entry: the sender on the first,
  # the text on the second, and the arrow alone on a third -- a full-height
  # button carrying no more meaning than the row it had been pushed off.
  # Eight entries filled the screen with mostly furniture.
  #
  # So the arrow is gone and the whole card takes the press, which is both
  # the larger target and the smaller thing to draw. What is left is what a
  # reader actually skims: who said it and where, then what they said.
  var list = vbox(%*{"spacing": 4})
  var n = 0
  for m in recentEverywhere(s.rooms, s.current):
    if n >= overviewLines: break
    n += 1
    # Each line carries the room it was said in, since that is the one thing a
    # line taken out of its own conversation no longer says for itself.
    list.children.add card(
      %*{"onClick": "overview.goto:" & m.room & ":" & rowId(m),
         "spacing": 2},
      hbox(%*{"spacing": 6}, dimLabel(m.room), label(m.frm)),
      # Two lines, and the cap is in lines rather than characters. How much
      # fits on one is a fact about the font and the width, and a character
      # count knows neither: 96 of them are two lines on a phone and five in
      # a widget test. `summarise` still bounds what crosses the wire, but
      # what a reader sees is bounded by the thing they are looking at.
      text(summarise(m.text, 160), lines = 2))
  if n == 0:
    list.children.add dimLabel("Nothing has happened anywhere else.")

  # The whole pane scrolls, heading and all. There were eight entries
  # because eight was all that could be seen: nothing here scrolled, so
  # what fell below the fold could not be reached at all.
  #
  # The heading scrolls with them rather than staying put, and that is not
  # the nicer arrangement -- it is the one that works. A fixed heading over
  # a scrolling list wants an `Expanded` inside this pane, and `expand` is
  # already how the pane claims its own share of the column; a second one
  # nested in the first asks a Column to shrink-wrap and fill at once.
  # Opened at its end, where the newest is. The entries read oldest-first
  # now, the way a conversation does, and a conversation is not something
  # you join at the beginning: what you came to the strip for is what has
  # just happened, and it should be under your eyes without scrolling for
  # it. `fromBottom` and not `stickToBottom` -- the latter also reports
  # whether the reader is at the present, and only the backlog has one.
  result = scroll(%*{"scrollKey": "overview", "orientation": "vertical",
                     "fromBottom": true},
    vbox(%*{"spacing": 4}, title2("Overview"), list))

proc lightboxPane(s: State): Node =
  ## The picture being looked at, as large as the window allows.
  ##
  ## A panel over the conversation rather than a screen of its own: closing it
  ## should put the reader back exactly where they were, and a screen would
  ## have to remember where that was.
  ##
  ## It used to be a card in the column with the picture capped at 640 by 480
  ## — which put a thumbnail-and-a-half below the backlog, off the bottom of
  ## a short window, and called it full size. Now it covers the conversation
  ## and the picture takes all of it.
  n("vbox", %*{"key": "lightbox-card", "spacing": 8, "margin": 12,
               "background": true, "expand": true}, @[
    hbox(%*{"spacing": 8, "wrap": false},
      title2("Picture"),
      n("button", %*{"label": "Close", "onClick": "lightbox.close",
                     "expand": true})),
    n("image", %*{"src": s.lightbox.url, "expand": true}),
    dimLabel(s.lightbox.url)])

proc profilePane(s: State): Node =
  ## Who someone is, behind the nick on a line.
  let nick = s.profileViewing.nick
  let actor = s.profileViewing.actor

  result = card(
    hbox(%*{"spacing": 8},
      title2(nick),
      button("Close", "profile.close")))

  if actor.len == 0:
    # A guest has no identity to fetch. The honest answer, rather than a
    # spinner that never lands.
    result.children.add dimLabel(
      "A guest — no Bluesky identity to look up.")
    return

  if isAgent(actor):
    result.children.add dimLabel(
      "An agent — it signs with a key of its own rather than a Bluesky " &
      "account, so there is no profile to show.")
    result.children.add dimLabel(actor)
    return

  let (p, known) = entry(actor)
  if not known or p.status == psLoading:
    result.children.add spinner()
    return
  if p.status == psFailed:
    result.children.add dimLabel("Could not look " & actor & " up.")
    return

  var head = hbox(%*{"spacing": 8})
  head.children.add avatar(p.avatar, nick, size = 64)
  var who = vbox(%*{"spacing": 2})
  if p.displayName.len > 0: who.children.add label(p.displayName)
  if p.handle.len > 0: who.children.add dimLabel("@" & p.handle)
  if p.did.len > 0: who.children.add dimLabel(p.did)
  head.children.add who
  result.children.add head

  if p.description.len > 0:
    result.children.add text(truncate(p.description, 280))

  let stats = statsLine(p)
  if stats.len > 0:
    result.children.add dimLabel(stats)

  let url = webUrl(p)
  if url.len > 0:
    result.children.add link("Open on bsky.app", url)

proc chatScreen*(s: State, connected: bool): Node =
  let room = s.currentRoom
  let name = if room.name.len > 0: room.name else: "Chat"
  let isChannel = room.name.startsWith("#")
  let showUsers = s.showUsers and isChannel
  # The chat list rides beside the backlog on a wide window. On a narrow one
  # there is `← Chats`, which goes to the list as a screen of its own — a
  # panel and a whole-screen list in the same place would be two ways to the
  # same thing, one of them cramped.
  let showChatList = s.wide and not s.hideChatList

  # What shares a line, and what gets one to itself.
  #
  # Every control used to sit beside the room's name and the row wrapped,
  # which put Overview alone on a second line looking like an orphan. The
  # measurements say why nothing subtler works: a chip here is 160.8 points,
  # of which 48 is Material's padding, so the three of them are 385 before
  # the name is drawn on a screen 360 wide. No amount of shrinking the name
  # fits that; at 360 it would be left about twenty points, which is not a
  # name, it is a hint.
  #
  # So the split is made deliberately instead of by overflow. The controls
  # are few, fixed and related, and they go together on one line in their
  # compact form. The name is the one element with no upper bound, and it
  # gets the width to itself -- which is also the answer to a long channel
  # name, where before it squeezed the controls and now it simply has the
  # room. Two lines either way, and this is the pair worth having.
  #
  # Not a horizontal scroll: a row you must drag to find a button in is a
  # worse answer than a name that trails off.
  let compact = not s.wide
  let chip = proc(text, event: string, on: bool): Node =
    if compact:
      button(text, event, if on: "compact-on" else: "compact")
    else:
      button(text, event, if on: "primary" else: "default")

  # `wrap` stays on where the name is not in this row: nothing in it is
  # flexible then, so wrapping is a safety net that costs nothing and never
  # fires at a real phone's width -- the three compact chips come to 352 of
  # 360. On a wide window the name is here and is `Flexible`, which a Wrap
  # cannot hold, so the row is a Row.
  var headRow = hbox(%*{"spacing": 8, "wrap": compact})

  # Each control that comes and goes is in a wrapper of its own, so a child
  # appearing does not renumber the row for the renderer.
  var back = vbox(%*{"key": "back"})
  if not s.wide:
    # The arrow without the word. "← Chats" measures 111 points of the 360
    # there are, and the row is 35 over with it; what dropping it buys is
    # People and Overview side by side, which is what this row is for. A
    # lone back arrow at the top left is not a thing anybody has to learn.
    back.children.add chip("←", "screen.chats", false)
  headRow.children.add back

  var fold = vbox(%*{"key": "fold"})
  if s.wide:
    # One label, lit while the list is up. It used to drop to a bare "☰" with
    # the list showing, which made the switch two different-looking controls in
    # the same slot and left the reader guessing which state they were in.
    fold.children.add chip("☰ Chats", "chat-list.toggle", not s.hideChatList)
  headRow.children.add fold

  # On a wide window the name still rides with the controls -- there is room
  # for it there, and a heading on a line of its own above four chips would
  # be a lot of empty space.
  if not compact:
    headRow.children.add title(name, shrink = true)

  var people = vbox(%*{"key": "people"})
  if isChannel:
    people.children.add chip("People " & $room.users.len, "users.toggle",
                             s.showUsers)
  headRow.children.add people

  # Not in a conditional wrapper: the overview is about every room rather than
  # this one, so it is offered in a DM and in a channel alike.
  headRow.children.add chip("Overview", "overview.toggle", s.overview)

  # The name, under the controls and across the whole width, on a narrow
  # window only.
  var heading = vbox(%*{"key": "room-name"})
  if compact:
    # `wrap: false`, because a shrinking title is `Flexible` and a Wrap
    # cannot hold one -- and without the Row there is nothing to shrink
    # against, so a long name would run off the edge instead of ellipsising.
    heading.children.add hbox(%*{"spacing": 0, "wrap": false},
                              title(name, shrink = true))

  # The backlog. Not a page — a page scrolls everything, which would carry the
  # compose bar off the bottom with the messages.
  # The backlog always has the middle, and always expands: a panel coming up
  # beside it takes a strip of the width, not the pane. It used to take the
  # whole of it on a narrow window, so asking who was in a room meant losing
  # the room while you looked.
  var messages = vbox(%*{"key": "messages", "expand": true})
  block:
    var sc = scroll(%*{"scrollKey": "messages-" & room.name,
                       "orientation": "vertical",
                       "stickToBottom": true,
                       "scrollToBottom": s.jumpTick})
    let shown = visible(s, room.messages)
    if shown.len > 0:
      for node in messageRows(s, room, shown):
        sc.children.add node
    else:
      sc.children.add dimLabel("Nothing here yet.")
    messages.children.add sc

  # The rooms, beside the one being read. Names rather than the cards the
  # chats screen uses: a card carries a preview and two buttons and is a
  # screen's worth of width, where this is a strip down one side.
  #
  # Neither strip scrolls, and that is a limit rather than a decision. A
  # `scroll` becomes an `Expanded`, and a `vbox` is always `MainAxisSize.min`
  # — which is the one combination Flutter will not lay out, and it came back
  # as a semantics assertion rather than anything mentioning either. A room
  # list or a member list longer than the window will run off the bottom
  # until a vbox can be told to fill its parent.
  var chatListPane = vbox(%*{"key": "chat-list-pane"})
  if showChatList:
    var panel = vbox(%*{"spacing": 4, "widthRequest": sidePanelWidth},
      title2("Chats"))
    var list = vbox(%*{"key": "chat-list", "spacing": 4})
    for r in channelList(s.rooms, ""):
      let unread = if r.unread > 0: "  " & (if r.mention: "◆ " else: "● ") &
                                    $r.unread
                   else: ""
      list.children.add n("button",
        %*{"key": "side-" & r.name, "label": r.name & unread,
           "kind": (if r.name == s.current: "primary" else: "plain"),
           "onClick": "room.open:" & r.name})
    panel.children.add list
    chatListPane.children.add panel

  var peoplePane = vbox(%*{"key": "people-pane"})
  if showUsers:
    var panel = vbox(%*{"spacing": 4, "widthRequest": sidePanelWidth},
      title2("People"))
    var list = vbox(%*{"key": "people-list", "spacing": 2})
    # Ops first, then alphabetically, with the mode prefix in front of the
    # name — the order every other client lists them in.
    for m in memberList(room.users):
      list.children.add label(m.prefix & m.nick)
    panel.children.add list
    peoplePane.children.add panel

  # Both panels are in wrappers that are always there, for the reason the
  # error note is: a child that comes and goes renumbers the row.
  # `expand` only while it is open, and that is not a detail: an empty
  # wrapper claiming a share of the column would take half the screen to
  # show nothing. Open, it splits the height with the backlog above it --
  # both scroll, so neither has to be given up for the other.
  var overview = vbox(%*{"key": "overview-pane"})
  if s.overview:
    overview.props["expand"] = %true
    overview.children.add overviewPane(s)

  var profile = vbox(%*{"key": "profile-pane"})
  if s.profileViewing.has:
    profile.children.add profilePane(s)

  # In the overlay rather than the column, and marked to fill it: a picture
  # being looked at should cover the conversation, not sit under it.
  var lightbox = vbox(%*{"key": "lightbox-pane", "fill": true})
  if s.lightbox.has:
    lightbox.children.add lightboxPane(s)

  var returnRow = vbox(%*{"key": "overview-back"})
  if s.overviewReturn.len > 0:
    returnRow.children.add button("← back to " & s.overviewReturn,
                                  "overview.back")

  # The same bar the other three screens carry, which this one did not have.
  # On a narrow window that was survivable: `← Chats` goes back to a screen
  # that has one. On a wide window there is no back button — the room list is
  # a strip instead — so Discover and Settings had no way in at all.
  #
  # Wide only, and not for symmetry's sake: a 300-point window puts these
  # three on two lines, and the chat screen has no 120 points to spare. It
  # overflowed the moment they were added unconditionally.
  var tabs = vbox(%*{"key": "tabs"})
  if s.wide:
    tabs.children.add tabBar(s)

  var jump = vbox(%*{"key": "jump"})
  if not s.atPresent:
    jump.children.add button("↓ Jump to present", "jump.present")

  # The three banners over the compose bar, each in its own stable wrapper.
  var banners = vbox(%*{"key": "banners", "spacing": 0})

  var replying = vbox(%*{"key": "replying"})
  if s.replyingTo.has:
    replying.children.add hbox(%*{"spacing": 8},
      dimLabel("↩ " & s.replyingTo.frm & ": " & summarise(s.replyingTo.text, 36)),
      button("✕", "reply.cancel"))
  banners.children.add replying

  var editing = vbox(%*{"key": "editing"})
  if s.editing.has:
    editing.children.add hbox(%*{"spacing": 8},
      emoji("📝", ""),
      dimLabel("Editing your message"),
      button("✕", "edit.cancel"),
      # Rewriting and unsending are the same decision taken two ways, and
      # this is the moment a reader is already looking at the line and
      # deciding what to do with it. `destructive` because it is: freeq
      # leaves a deleted line out of history, so there is nothing to undo
      # it with.
      button("Delete", "edit.delete", "destructive"))
  banners.children.add editing

  var attach = vbox(%*{"key": "attachment"})
  if s.attachment.has:
    attach.children.add hbox(%*{"spacing": 8},
      image(s.attachment.path, maxHeight = 64),
      dimLabel(if s.attachment.status == usUploading: "Uploading…"
               else: "Picture attached"),
      button("✕", "attachment.clear"))
  banners.children.add attach

  # The compose bar. The picture button is a tile rather than an emoji: the
  # emoji was a colour photo that matched nothing else in the bar.
  # `wrap: false`, so this is a row and the box can take what the picture
  # button and Send leave. It was a Wrap with the box pinned to 260 points,
  # which is a message box the width of a phone's on a window four times
  # that — and the rest of the line empty beside it.
  var compose = hbox(%*{"spacing": 8, "align": "center", "marginBottom": 12,
                        "wrap": false},
    image("asset:assets/insert-image.png", maxWidth = 36, maxHeight = 36,
          onClick = "image.pick"),
    entry("draft", s.draft, "Message " & name, "draft.change",
          onSubmit = "send"),
    button("Send", "send", "primary"))

  vbox(%*{"spacing": 8, "margin": 12, "expand": true},
    headRow,
    heading,
    errorNote(s),
    # `expand` on the row itself: it is the thing that takes the column's
    # remaining height. The renderer used to infer that by looking at this
    # row's children, which is the prop being on the wrong node.
    # The jump button floats over the backlog rather than taking a row of
    # its own; see `ui.overlay`.
    overlay(%*{"key": "backlog", "expand": true},
      # The split: the rooms on one side, the people on the other, and the
      # conversation between them taking whatever is left.
      n("hbox", %*{"spacing": 8, "wrap": false, "expand": true},
        @[chatListPane, messages, peoplePane]),
      jump, lightbox),
    overview,
    profile,
    returnRow,
    banners,
    separator(),
    compose,
    tabs)
