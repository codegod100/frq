## Every event the screens can send, and what it does to the state.
##
## This is `common/frq/actions.cljc` and the reducers scattered through
## `frq.main` in one place. In the Clojure `frq.actions` is a table of
## closures the host installs, and it is a table precisely because the screens
## are compiled separately from the thing that answers them. Here they are the
## same program, so it is a case statement.
##
## Event ids are strings with a `:`-separated argument, because that is what
## crosses the FFI in a prop. `room.open:#test` rather than a structured
## payload: the alternative is a second serialisation to define and version,
## for arguments that are always one string.

import std/[json, options, sequtils, strutils, tables]
import frq/[cells, model, rooms, reactions, edits, trace, ircparse, clock]
import frq/conn as tr

proc split2(id: string): (string, string) =
  ## `"room.open:#test"` → `("room.open", "#test")`. The argument may itself
  ## contain colons — a reaction event carries an emoji and an id — so only
  ## the first is a separator.
  let i = id.find(':')
  if i < 0: (id, "") else: (id[0 ..< i], id[i + 1 .. ^1])

proc setError(msg: string) =
  app.error = msg
  app.hasError = true

proc send(line: string) =
  trace("out", line)
  tr.send(line)

proc openRoom(name: string) =
  app.rooms.ensureRoom(name)
  var r = app.rooms[name]
  r.accessed = nowMs()
  app.rooms[name] = r
  app.current = name
  app.screen = scChat
  app.atPresent = true
  # Opening a room is reading it: the marker moves to the newest line here.
  app.rooms[name] = app.rooms[name].markRead

proc connectNow() =
  if app.formHost.strip().len == 0:
    setError("A server is required."); return
  if app.formNick.strip().len == 0:
    setError("A nickname is required."); return
  app.connecting = true
  app.hasError = false
  app.status = "Connecting to " & app.formHost & ":" & app.formPort &
               (if app.formTls: " over TLS" else: "") & "…"
  let port = try: parseInt(app.formPort.strip())
             except ValueError: (if app.formTls: 6697 else: 6667)
  tr.open(tr.ConnConfig(host: app.formHost.strip(), port: port,
                        tls: app.formTls))

proc sendDraft() =
  let text = app.draft.strip()
  if text.len == 0 or app.current.len == 0: return

  if app.editing.has:
    # An edit is a fresh PRIVMSG tagged with what it replaces; the server
    # rewrites the original and echoes the revision back.
    send("@+draft/edit=" & app.editing.id & " PRIVMSG " & app.current &
         " :" & text)
    app.editing = EditTarget()
  elif app.replyingTo.has:
    send("@+draft/reply=" & app.replyingTo.id & " PRIVMSG " & app.current &
         " :" & text)
    app.replyingTo = ReplyTarget()
  else:
    send("PRIVMSG " & app.current & " :" & text)

  # Echoed locally, because the server does not send your own PRIVMSG back
  # unless echo-message was negotiated — and every client that forgets this
  # looks like it dropped the message.
  var r = app.rooms[app.current]
  var m = Message(frm: app.formNick, text: text, at: nowMs(),
                  localId: "local-" & $r.messages.len, pending: true)
  m.imageUrl = app.attachment.url
  r.messages.add m
  app.rooms[app.current] = r.markRead
  app.draft = ""
  app.attachment = Attachment()

proc dispatch*(event: JsonNode) =
  let raw = event{"id"}.getStr()
  let value = event{"value"}.getStr()
  let (id, arg) = split2(raw)

  traced "event": "→ " & raw &
    (if value.len > 0: " value=" & value.escape else: "")

  case id
  # ------------------------------------------------------------ the form
  of "mode.guest": app.authMode = amGuest
  of "mode.bluesky": app.authMode = amBluesky
  of "mode.app-password": app.authMode = amAppPassword

  of "host.change": app.formHost = value
  of "port.change": app.formPort = value
  of "nick.change": app.formNick = value
  of "handle.change": app.formHandle = value
  of "app-password.change": app.formAppPassword = value

  of "tls.toggle":
    app.formTls = not app.formTls
    # The port follows the tick, as the Clojure's :on-toggled does.
    app.formPort = if app.formTls: "6697" else: "6667"

  of "session.forget":
    app.brokerToken = ""
    app.status = "Saved session forgotten."

  # --------------------------------------------------------- the connection
  of "connect": connectNow()

  of "cancel", "disconnect":
    tr.close()
    app.connecting = false
    app.screen = scConnect
    app.status = "Not connected"

  of "error.dismiss":
    app.error = ""
    app.hasError = false

  # ------------------------------------------------------------- navigation
  of "screen.connect": app.screen = scConnect
  of "screen.chats": app.screen = scChats
  of "screen.discover": app.screen = scDiscover
  of "screen.settings": app.screen = scSettings

  of "room.open": openRoom(arg)

  of "room.join":
    if arg.len > 0:
      app.rooms.ensureRoom(arg)
      var r = app.rooms[arg]
      r.joining = true
      app.rooms[arg] = r
      send("JOIN " & arg)
      openRoom(arg)

  of "room.leave":
    if app.rooms.hasKey(arg):
      if not dm(arg): send("PART " & arg)
      app.rooms.del(arg)
      if app.current == arg:
        app.current = ""
        app.screen = scChats

  of "join":
    # `@nick` opens a DM, which needs no JOIN — there is nothing to be in.
    let want = app.joinInput.strip()
    if want.len > 0:
      if want.startsWith("@"):
        openRoom(want[1 .. ^1])
      else:
        let name = if want.startsWith("#"): want else: "#" & want
        app.rooms.ensureRoom(name)
        send("JOIN " & name)
        openRoom(name)
      app.joinInput = ""

  of "join-input.change": app.joinInput = value
  of "search.change": app.search = value
  of "search.clear": app.search = ""

  # ---------------------------------------------------------- chat chrome
  of "chat-list.toggle": app.hideChatList = not app.hideChatList
  of "users.toggle": app.showUsers = not app.showUsers
  of "overview.toggle": app.overview = not app.overview
  of "join-part.toggle": app.hideJoinPart = not app.hideJoinPart
  of "jump.present":
    app.atPresent = true
    app.jumpTick += 1

  # ------------------------------------------------------------ the compose
  of "draft.change": app.draft = value
  of "send": sendDraft()

  of "reply.to":
    let m = app.currentRoom.messageById(arg)
    if m.isSome:
      app.replyingTo = ReplyTarget(has: true, id: arg, frm: m.get.frm,
                                   text: m.get.text)
      app.editing = EditTarget()
  of "reply.cancel": app.replyingTo = ReplyTarget()

  of "edit.start":
    let m = app.currentRoom.messageById(arg)
    if m.isSome and m.get.frm == app.formNick:
      app.editing = EditTarget(has: true, room: app.current, id: arg)
      app.replyingTo = ReplyTarget()
      # The wording goes into the box: what is being rewritten is what the
      # reader edits, not an empty field.
      app.draft = m.get.text
  of "edit.cancel":
    app.editing = EditTarget()
    app.draft = ""

  of "attachment.clear": app.attachment = Attachment()

  # -------------------------------------------------------------- reactions
  of "react.open":
    app.reacting = ReactTarget(has: true, room: app.current, id: arg)
  of "react.close": app.reacting = ReactTarget()

  of "react.toggle":
    # `id:emoji`, and the emoji may contain nothing colon-like so one more
    # split is enough.
    let (mid, emoji) = split2(arg)
    if mid.len > 0 and emoji.len > 0:
      let m = app.currentRoom.messageById(mid)
      let on = if m.isSome: not m.get.mine(emoji, app.formNick) else: true
      send("@+draft/react=" & emoji & ";+draft/reply=" & mid &
           " TAGMSG " & app.current)
      app.rooms.updateReaction(app.current, mid, emoji, app.formNick, on)

  of "goto":
    app.jumpTo = arg
    app.highlight = arg

  of "lightbox":
    app.lightbox = Lightbox(has: true, url: arg, path: arg)
  of "lightbox.close": app.lightbox = Lightbox()

  of "quit": discard   # the host's business; the tree only says it was asked

  else:
    trace("event", "!! no handler for " & raw.escape & " — ignored")

# ------------------------------------------------------------------- drain
#
# The socket thread's output, turned into state. Called before a render, so
# the tree the renderer gets is built after every line that had arrived when
# it asked.

proc note(room: string, m: Message) =
  app.rooms.ensureRoom(room)
  var r = app.rooms[room]
  if seenMessage(r.messages, m.id, m.frm, m.text, app.formNick): return
  r.messages.add m
  r.lastActivity = nowMs()
  app.rooms[room] = r.recount(app.formNick)

proc drain*() =
  while true:
    let (ok, e) = tr.tryEvent()
    if not ok: break
    trace("status", e)
    if e == "open":
      # The client speaks first in IRC. CAP before registration, the order the
      # server expects and the order `frq.main` used.
      #
      # No SASL yet: this registers as a guest. The Bluesky handshake is
      # `frq.irc.handshake` and has not been ported, so the two signed-in
      # modes on the connect screen reach this point and land as guests —
      # which the connect screen does not yet say, and should.
      send("CAP LS 302")
      send("NICK " & app.formNick)
      send("USER " & app.formNick & " 0 * :frq")
      app.status = "Registering…"
    elif e.startsWith("error:"):
      app.connecting = false
      setError(e[6 .. ^1].strip())
      app.status = "Not connected"
    elif e.startsWith("close:"):
      app.connecting = false
      app.status = "Disconnected"

  while true:
    let (ok, line) = tr.tryLine()
    if not ok: break
    let p = parseLine(line)

    # PING is the transport's housekeeping and the screens have no opinion.
    if p.command == "PING":
      send("PONG :" & (if p.params.len > 0: p.params[^1] else: ""))
      continue

    let (tagMs, hasTime) = parseTimeTag(p.tags)
    let at = if hasTime: tagMs else: nowMs()
    let msgid = block:
      let (v, ok2) = tagValue(p.tags, "msgid")
      if ok2: v else: ""

    case p.command
    of "CAP":
      # Nothing is requested yet — no SASL, no message-tags of our own — so
      # the negotiation is ended immediately. A CAP LS with no END leaves the
      # server waiting and registration never completes.
      if p.params.len >= 2 and p.params[1] == "LS":
        send("CAP END")

    of "001":
      app.connecting = false
      app.status = "Connected as " & app.formNick
      app.screen = scChats
      send("JOIN #test")

    of "PRIVMSG":
      if p.params.len >= 2:
        let target = p.params[0]
        let who = nickOf(p.prefix)
        # A message to us rather than to a channel belongs in a buffer named
        # for the sender: the target is our own nick and is nobody's room.
        let room = if target.startsWith("#"): target else: who
        var m = Message(id: msgid, frm: who, text: p.params[^1], at: at)
        m.imageUrl = ""
        let (rep, hasRep) = tagValue(p.tags, "+reply")
        if hasRep: m.replyTo = rep
        let (tally, hasTally) = tagValue(p.tags, "+freeq.at/reacts")
        if hasTally: m.reactions = parseTally(tally)
        note(room, m)

    of "JOIN":
      if p.params.len >= 1:
        let room = p.params[0]
        app.rooms.ensureRoom(room)
        var r = app.rooms[room]
        let who = nickOf(p.prefix)
        if who == app.formNick:
          r.joined = true
          r.joining = false
        elif who notin r.users:
          r.users.add who
        app.rooms[room] = r
        note(room, Message(frm: "*", text: who & " joined " & room,
                           at: at, system: true))

    of "PART", "QUIT":
      let who = nickOf(p.prefix)
      let room = if p.params.len >= 1: p.params[0] else: app.current
      if app.rooms.hasKey(room):
        var r = app.rooms[room]
        r.users = r.users.filterIt(it != who)
        app.rooms[room] = r
        note(room, Message(frm: "*", text: who & " left", at: at,
                           system: true))

    of "353":
      # NAMES: the membership, as a space-separated list in the trailing.
      if p.params.len >= 2:
        let room = p.params[^2]
        if app.rooms.hasKey(room):
          var r = app.rooms[room]
          for u in p.params[^1].split(' '):
            let nick = u.strip(chars = {'@', '+', '~', '&', '%', ' '})
            if nick.len > 0 and nick notin r.users: r.users.add nick
          app.rooms[room] = r

    of "332":
      if p.params.len >= 2 and app.rooms.hasKey(p.params[^2]):
        var r = app.rooms[p.params[^2]]
        r.topic = p.params[^1]
        app.rooms[p.params[^2]] = r

    of "NOTICE":
      if p.params.len >= 2:
        note(if app.current.len > 0: app.current else: "#test",
             Message(frm: "notice", text: p.params[^1], at: at, system: true))

    of "432", "433", "436":
      # Nickname refused — the likeliest way a guest connect fails and the
      # least obvious, so it is named rather than shown as a numeric.
      setError("That nickname is taken or invalid.")
      app.connecting = false

    else:
      trace("skip", p.command & " " & $p.params)
