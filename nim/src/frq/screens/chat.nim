## The room, once there is one.
##
## The spike's destination: a backlog, a box, and a Send. Small on purpose —
## the point is that a line typed here reaches #test and a line from #test
## arrives here, not that it looks like the finished client.

import std/json
import ../ui, ../state

func messageRow(m: Message): Node =
  if m.frm == "*":
    # Comings and goings, dimmer than what people said.
    dimLabel(m.text)
  elif m.frm == "notice":
    dimLabel("— " & m.text)
  else:
    hbox(%*{"spacing": 6},
      label(m.frm & ":"),
      label(m.text))

func chatScreen*(s: State): Node =
  var rows: seq[Node]
  # The last fifty, newest at the bottom. A cap rather than a scrollback
  # policy: the tree crosses the boundary whole on every render, and an
  # unbounded backlog is the one thing that would make that cost matter.
  let start = max(0, s.messages.len - 50)
  for i in start ..< s.messages.len:
    rows.add messageRow(s.messages[i])
  if rows.len == 0:
    rows.add dimLabel("Nothing yet. Say something.")

  page(%*{"maxWidth": 640},
    hbox(%*{"spacing": 8},
      title(s.channel),
      dimLabel(s.status),
      button("Disconnect", "disconnect")),
    card(
      scroll(%*{"height": 380},
        n("vbox", %*{"spacing": 4}, rows))),
    hbox(%*{"spacing": 8},
      entry("draft", s.draft, "Message " & s.channel, "draft.change",
            width = 460),
      button("Send", "send", "primary")))
