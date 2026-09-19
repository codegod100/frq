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
from std/unicode import runeLen, runeSubStr
import std/options
import frq/[ui, cells, model, clock, reactions, textruns]
from frq/screens/connect import errorNote

const
  faceSize = 32
  pillSize = 20
  chipGap = 4
  overviewLines* = 8

func summarise*(text: string, n: int): string =
  ## What a reply chip quotes back. One line, cut to fit.
  var line = newStringOfCap(text.len)
  var inSpace = false
  for c in text:
    if c in {' ', '\t', '\n', '\r'}:
      if not inSpace: line.add ' '
      inSpace = true
    else:
      line.add c
      inSpace = false
  line = line.strip()
  # Runes, not bytes: a byte slice lands inside a multi-byte character and
  # makes mojibake where an ellipsis was wanted.
  if line.runeLen > n: line.runeSubStr(0, n - 1) & "…" else: line

func actionChips(room: string, m: Message, mine: bool): Node =
  ## Answering and reacting, on the sender's row above the message.
  ##
  ## Both are things done *to* a message rather than parts of it, so they ride
  ## the sender's row against its right edge, at the size a reaction is. In
  ## the line with the text they took width off every line under them and
  ## wrapped a message that had the room to sit on one.
  ##
  ## A row laid out from the right lays its first child furthest right, so
  ## reacting comes first here and this reads ✏️ then ↩️ then 🙂 on screen.
  ## Only our own lines carry a pencil: the server refuses an edit of somebody
  ## else's, and a chip that always fails is a chip that lies.
  result = n("hbox", %*{"key": "actions", "align": "end", "spacing": chipGap}, @[
    n("reaction", %*{"key": "react", "emoji": "🙂", "size": pillSize,
                     "onClick": "react.open:" & rowId(m)}),
    n("reaction", %*{"key": "reply", "emoji": "↩️", "size": pillSize,
                     "onClick": "reply.to:" & rowId(m)})])
  if mine:
    result.children.add n("reaction",
      %*{"key": "edit", "emoji": "✏️", "size": pillSize,
         "onClick": "edit.start:" & rowId(m)})

func reactionRow(m: Message, me: string): Node =
  ## What people have put on a message, under it.
  ##
  ## A pill carries its count and toggles: clicking one you are already on
  ## takes yours off, which is the same gesture that put it there. `reaction`
  ## rather than a button with the emoji as its label — the chip draws the
  ## glyph from the Twemoji pack, in colour, where a label gets whatever the
  ## text font has.
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
  result = n("hbox", %*{"key": "runs", "wrap": true, "inline": true})
  for r in textRuns(m.text):
    case r.kind
    of rkText: result.children.add text(r.value)
    of rkLink: result.children.add link(r.value, r.value)

proc messageBody(s: State, m: Message, highlit: bool): Node =
  ## A message without its face: the sender's line, the words, and what hangs
  ## under them.
  var who = vbox(%*{"key": "who"})
  if m.system:
    if m.at > 0:
      who.children.add dimLabel(clockTime(m.at))
  else:
    var row = hbox(%*{"spacing": 6},
      avatar("", m.frm, size = faceSize),
      label(m.frm))
    if m.at > 0:
      row.children.add dimLabel(clockTime(m.at))
    if m.edited:
      row.children.add dimLabel("(edited)")
    if m.id.len > 0:
      row.children.add actionChips(s.current, m, m.frm == s.formNick)
    else:
      # A spacer where the chips would be, so a line with no msgid is a row of
      # the same shape rather than a row with a hole in it.
      row.children.add spacer(0)
    who.children.add row

  # The reply chip is in a wrapper that is always there, for the reason the
  # error note is: a child that comes and goes renumbers the row.
  var chip = vbox(%*{"key": "reply-chip"})
  if m.replyTo.len > 0:
    let target = s.currentRoom.messageById(m.replyTo)
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

  var pills = vbox(%*{"key": "reactions-row", "marginTop": 6})
  if m.id.len > 0 and not m.system and m.reactions.len > 0:
    pills.children.add reactionRow(m, s.formNick)

  # A card when the jump landed here, a plain box otherwise — the highlight is
  # how a reader finds the line they were sent to.
  n(if highlit: "card" else: "vbox",
    %*{"key": (if highlit: "body-card" else: "body-plain"),
       "spacing": 2, "margin": 0},
    @[who, body, images, pills])

proc messageRow(s: State, i: int, m: Message): Node =
  ## One message: who said it, when, what you can do to it, and the words.
  ##
  ## Every line names its sender, rather than the first of a run only. A run
  ## collapsed to one heading reads well until you answer the fourth line of
  ## it, and then the line quoted back has no name on it; and the actions live
  ## on the sender's row, which a headerless line has nowhere to put.
  let rid = rowId(m)
  let highlit = rid.len > 0 and rid == s.highlight
  n("vbox", %*{"key": $i, "spacing": 2, "margin": 0, "marginRight": 10,
               "marginTop": 10,
               "scrollHere": rid.len > 0 and rid == s.jumpTo},
    @[messageBody(s, m, highlit)])

func daySeparator(key, label0: string): Node =
  n("hbox", %*{"key": key, "spacing": 8}, @[separator(), dimLabel(label0)])

proc messageRows*(s: State, messages: seq[Message]): seq[Node] =
  ## The messages, with a heading wherever the day changes.
  ##
  ## A backlog can reach back weeks, and `11:04 AM` says nothing about which
  ## day it was. The heading is what makes the time above it mean something.
  for i, m in messages:
    if m.at > 0:
      let d = day(m.at)
      let prevDay = if i > 0 and messages[i - 1].at > 0: day(messages[i - 1].at)
                    else: ""
      if d != prevDay:
        result.add daySeparator("day-" & $i, dayLabel(m.at))
    result.add messageRow(s, i, m)

proc visible(s: State, messages: seq[Message]): seq[Message] =
  ## The lines this reader wants to see. Comings and goings are the room
  ## talking about itself; a quiet room reads better with them and a busy one
  ## drowns in them, so it is the reader's call.
  for m in messages:
    if s.hideJoinPart and m.system: continue
    result.add m

proc chatScreen*(s: State, connected: bool): Node =
  let room = s.currentRoom
  let name = if room.name.len > 0: room.name else: "Chat"
  let isChannel = room.name.startsWith("#")
  let showUsers = s.showUsers and isChannel
  # Beside the backlog only where there is room for both. On a narrow window
  # the panel is the pane, and the backlog stands down for as long as it is up.
  let narrowPeople = showUsers and not s.wide

  # Wrapping, because on a phone this row asks for more than there is: ← Chats,
  # the room's name, People and Overview do not fit across 360 points, and in a
  # Row every one of them is a flex child sharing what there is — so Overview
  # was allotted a quarter of the width and painted itself "Overvi…".
  var headRow = hbox(%*{"spacing": 8, "wrap": true})

  # Each control that comes and goes is in a wrapper of its own, so a child
  # appearing does not renumber the row for the renderer.
  var back = vbox(%*{"key": "back"})
  if not s.wide:
    back.children.add button("← Chats", "screen.chats")
  headRow.children.add back

  var fold = vbox(%*{"key": "fold"})
  if s.wide:
    # One label, lit while the list is up. It used to drop to a bare "☰" with
    # the list showing, which made the switch two different-looking controls in
    # the same slot and left the reader guessing which state they were in.
    fold.children.add button("☰ Chats", "chat-list.toggle",
                             if not s.hideChatList: "primary" else: "default")
  headRow.children.add fold

  headRow.children.add title(name)

  var people = vbox(%*{"key": "people"})
  if isChannel:
    people.children.add button("People " & $room.users.len, "users.toggle",
                               if s.showUsers: "primary" else: "default")
  headRow.children.add people

  # Not in a conditional wrapper: the overview is about every room rather than
  # this one, so it is offered in a DM and in a channel alike.
  headRow.children.add n("button",
    %*{"key": "overview-toggle", "label": "Overview",
       "kind": (if s.overview: "primary" else: "default"),
       "onClick": "overview.toggle"})

  # The backlog. Not a page — a page scrolls everything, which would carry the
  # compose bar off the bottom with the messages.
  var messages = vbox(%*{"key": "messages", "fillHeight": not narrowPeople})
  if not narrowPeople:
    var sc = scroll(%*{"scrollKey": "messages-" & room.name,
                       "orientation": "vertical",
                       "stickToBottom": true,
                       "scrollToBottom": s.jumpTick})
    let shown = visible(s, room.messages)
    if shown.len > 0:
      for node in messageRows(s, shown):
        sc.children.add node
    else:
      sc.children.add dimLabel("Nothing here yet.")
    messages.children.add sc

  var peoplePane = vbox(%*{"key": "people-pane"})
  if showUsers:
    var panel = vbox(%*{"spacing": 4, "widthRequest": 150},
      title2("People"))
    for u in room.users:
      panel.children.add label(u)
    peoplePane.children.add panel

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
      emoji("✏️", ""),
      dimLabel("Editing your message"),
      button("✕", "edit.cancel"))
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
  var compose = hbox(%*{"spacing": 8, "align": "center", "marginBottom": 12},
    image("asset:assets/insert-image.png", maxWidth = 36, maxHeight = 36,
          onClick = "image.pick"),
    entry("draft", s.draft, "Message " & name, "draft.change",
          width = 260, onSubmit = "send"),
    button("Send", "send", "primary"))

  vbox(%*{"spacing": 8, "margin": 12, "fillHeight": true},
    headRow,
    errorNote(s),
    hbox(%*{"spacing": 8, "wrap": false}, messages, peoplePane),
    jump,
    banners,
    separator(),
    compose)
