## The conversation list.
##
## Transcribed from `common/frq/screens/chats.cljc`. The terminal branches are
## dropped rather than translated — there is no terminal frontend any more, so
## `conversation-row`'s two layouts collapse to the one a window uses.

import std/[json, strutils]
import frq/[ui, cells, model, rooms, textruns]
import frq/screens/[frame, connect]

const listGutter = 16
  ## The scrollbar's room. Without it the cards sit under it and the last
  ## character of a preview is behind the thumb.

func previewLine*(text: string): string =
  ## The last line of a conversation, as one line, cut to fit a card.
  ##
  ## 60 characters is the card's width; the truncating itself is
  ## `textruns.summarise`, which the reply chip in the chat screen uses for
  ## the same job.
  summarise(text, 60)

func conversationRow(r: Room): Node =
  var badges = vbox(%*{"key": "badges"})
  # A room we have not joined is one the reader can see but is not in — worth
  # saying, because Open and Close both work on it either way.
  let away = not dm(r.name) and not r.joined
  if away or r.unread > 0:
    var row = hbox(%*{"spacing": 12, "wrap": false})
    if away:
      row.children.add status("not joined", live = false)
    if r.unread > 0:
      row.children.add label((if r.mention: "◆ @ " else: "● ") & $r.unread)
    badges.children.add row

  n("vbox", %*{"key": r.name, "marginRight": listGutter}, @[
    card(
      title2(r.name),
      badges,
      dimLabel(previewLine(r.lastPreview)),
      hbox(%*{"spacing": 8, "wrap": false},
        button("Open", "room.open:" & r.name),
        button("Close", "room.leave:" & r.name)))])

func chatsScreen*(s: State, connected: bool): Node =
  let buffers = channelList(s.rooms, s.search)

  var head = vbox(%*{"key": "head", "spacing": 8, "marginRight": listGutter},
    title(if connected: "Logged in as " & s.formNick else: "Chats"),
    errorNote(s))

  # `@nick` opens a DM and `#room` joins a channel, and the button says which
  # so the reader is not guessing what Enter will do.
  var joinRow = hbox(%*{"spacing": 8, "align": "end"},
    button(if s.joinInput.startsWith("@"): "Message" else: "Join", "join"),
    entry("join-input", s.joinInput, "#channel or @nick", "join-input.change",
          onSubmit = "join", verbatim = true))

  var searchRow = hbox(%*{"spacing": 8, "align": "end"})
  if s.search.len > 0:
    searchRow.children.add button("✕", "search.clear")
  searchRow.children.add entry("search", s.search, "Search channels",
                               "search.change")

  head.children.add card(vbox(%*{"spacing": 8}, joinRow, searchRow))

  var body: Node
  if buffers.len > 0:
    body = vbox(%*{"spacing": 8})
    for b in buffers:
      body.children.add conversationRow(b)
  else:
    body = n("vbox", %*{"marginRight": listGutter}, @[
      card(dimLabel("No conversations yet — join a channel."))])

  vbox(%*{"spacing": 8, "margin": 12, "expand": true},
    head,
    vbox(%*{"key": "list", "expand": true},
      scroll(%*{"scrollKey": "chats-list", "orientation": "vertical"}, body)),
    vbox(%*{"key": "foot", "spacing": 8},
      separator(),
      tabBar(s)))
