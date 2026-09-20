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
import std/sets
import frq/[cells, model, rooms, reactions, trace, ircparse, clock,
           atproto, handshake, textruns, members, msgsig, profile, store,
           profilefetch]
import frq/conn as tr
import frq/oauth as oa

proc split2(id: string): (string, string) =
  ## `"room.open:#test"` → `("room.open", "#test")`. The argument may itself
  ## contain colons — a reaction event carries an emoji and an id — so only
  ## the first is a separator.
  let i = id.find(':')
  if i < 0: (id, "") else: (id[0 ..< i], id[i + 1 .. ^1])

var
  session: Session
    ## What this connection is signing in as, settled before the socket opens.
  caps: HashSet[string]
    ## What the server has ACKed so far, threaded through `handshake.step`.

proc setError(msg: string) =
  app.error = msg
  app.hasError = true

const historyLimit = 100
  ## How many lines of backlog to ask a room for.

proc rememberRooms(force = false)
  ## Declared here because `openRoom` is above it and calls it — the file is
  ## ordered by what the reader does, not by what calls what.

proc wantFace(m: Message)
  ## And this because `sendDraft` is: our own line wants a face as much as
  ## anybody's.

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
  # Both of the things the file keeps just changed — where this room sits in
  # the list, and how much of it has been read. Throttled, so a reader
  # flicking through five rooms writes once.
  rememberRooms()

proc restoreRooms() =
  ## The rooms of earlier runs, in the order they were last used.
  ##
  ## Empty buffers, not memberships: the list of rooms is the part worth
  ## keeping and the messages in them come from the server. What makes a
  ## returning backlog readable is the marker beside each name — without one
  ## every replayed line is new and every room comes back with its whole
  ## history unread.
  ##
  ## Inserted oldest first, so the table's own order matches the list the
  ## reader last saw; `accessed` comes back from the file, so anything that
  ## sorts agrees with it. A record with no marker at all — an older frq's
  ## file, or one that lost it — is caught up to now rather than counted from
  ## the beginning, which is the kinder of the two wrong answers.
  let saved = loadRooms()
  if saved.len == 0: return
  for i in countdown(saved.high, 0):
    let r = saved[i]
    if app.rooms.hasKey(r.name): continue
    var ch = initRoom(r.name)
    ch.accessed = r.accessed
    ch.lastReadId = r.lastReadId
    ch.lastReadAt = if r.lastReadAt > 0: r.lastReadAt else: nowMs()
    app.rooms[r.name] = ch
  trace("store", $saved.len & " rooms remembered")

proc restorePrefs() =
  ## The display toggles that are a standing answer rather than a passing
  ## one: whether the comings and goings are worth seeing, and whether the
  ## room list is out of the way.
  ##
  ## The member list is NOT among them, though it was for a day. On a narrow
  ## window the people panel is not beside the conversation, it *is* the
  ## pane — so a saved "on" meant opening a room and being shown a list of
  ## names instead of the room, every launch, having asked for it once. It is
  ## a way of looking at the moment you are in, like the overview, and those
  ## start off.
  let prefs = loadPrefs()
  app.hideJoinPart = prefs.getOrDefault("hideJoinPart", app.hideJoinPart)
  app.hideChatList = prefs.getOrDefault("hideChatList", app.hideChatList)

proc rememberPrefs() =
  discard savePrefs({"hideJoinPart": app.hideJoinPart,
                     "hideChatList": app.hideChatList}.toTable)

var
  roomsSavedAt: int64 = 0
  roomsWritten: string

proc roomsDigest(): string =
  ## Exactly the fields the file holds, so "nothing changed" means nothing
  ## the file would show changed. A message arriving in a room nobody is
  ## looking at moves `lastActivity`, which is not saved and must not cost a
  ## write.
  for name, r in app.rooms:
    result.add name & "\x1f" & $r.accessed & "\x1f" & r.lastReadId &
               "\x1f" & $r.lastReadAt & "\x1e"

proc rememberRooms(force = false) =
  ## Write the room list out, at most every five seconds.
  ##
  ## Throttled because the things that move a marker — opening a room,
  ## reading one, a line arriving in the one you are looking at — happen in
  ## bursts, and a file write per line is a file write per line.
  ##
  ## A late write costs at most the handful of lines that arrived since the
  ## last one, shown unread again next run. That is the right way round: the
  ## marker never claims to have read more than it has. `force` is for the
  ## moments there may not be a next chance — leaving a room, disconnecting.
  let now = nowMs()
  if not force and now - roomsSavedAt < 5000: return
  # `drain` calls this on every frame, so the throttle alone would write the
  # same file every five seconds for as long as the app is open.
  let digest = roomsDigest()
  if digest == roomsWritten: return
  roomsSavedAt = now
  roomsWritten = digest
  discard saveRooms(app.rooms)

proc restore*() =
  ## What a previous run left on disk, back in the state.
  ##
  ## Three files, and they answer three different questions: who you are, what
  ## you were in, and how you like it. Any of them may be missing, and a run
  ## with none of them is a first run rather than an error.
  restoreRooms()
  restorePrefs()
  let (saved, had) = loadSession()
  if not had: return
  # The broker token is what saves the reader a login page, and the mode goes
  # with it: a remembered session is not much use sitting behind the Guest
  # tab. The nick and handle come along so the screen says who it is about
  # before the broker is asked.
  app.brokerToken = saved.brokerToken
  app.authMode = amBluesky
  if saved.handle.len > 0: app.formHandle = saved.handle
  if saved.nick.len > 0: app.formNick = saved.nick
  trace("oauth", "a saved session for " & saved.handle)

proc adoptTokens(t: oa.Tokens) =
  ## A broker handoff, become an identity.
  ##
  ## The nick and the handle are set together for the reason the app-password
  ## path sets them together: the channel calls us one thing and the client
  ## believes another otherwise, and every "is this me?" test comes back
  ## false. The broker's `nick` wins where it sent one — it is what the server
  ## has already decided to call this DID.
  session = Session(kind: skWebToken, token: t.token,
                    did: t.did, handle: t.handle)
  if t.handle.len > 0: app.formHandle = t.handle
  let nick = if t.nick.len > 0: t.nick else: t.handle
  if nick.len > 0: app.formNick = nick
  # Only the durable half is written: the web-token beside it is single-use
  # and would be a stale secret on disk by the time anything read it.
  app.brokerToken = t.brokerToken
  discard saveSession(SavedSession(brokerToken: t.brokerToken,
                                   handle: app.formHandle, did: t.did,
                                   nick: app.formNick))
  trace("oauth", "signed in as " & t.did)

proc signIn(): bool =
  ## Whatever identity was asked for, settled before the socket opens.
  ##
  ## An app-password sign-in is an HTTPS round trip that has nothing to do
  ## with IRC, and a failure in it must stop here: connecting anyway lands us
  ## on the server as a guest, which looks like a success and is not the one
  ## that was asked for.
  session = Session()
  caps = initHashSet[string]()
  case app.authMode
  of amGuest:
    true
  of amAppPassword:
    if app.formHandle.strip().len == 0:
      setError("A handle is required."); return false
    if app.formAppPassword.len == 0:
      setError("An app password is required."); return false
    try:
      app.status = "Signing in to your PDS…"
      session = createSession(app.formHandle, app.formAppPassword)
      # The nick is what the channel calls us and the DID is the identity;
      # both halves have to agree, so the handle becomes the nick. Sending the
      # handle here and a different nick at registration is what once had the
      # channel calling us alice.bsky.social while the client thought it was
      # alice, so every "is this me?" test came back false.
      app.formNick = session.handle
      app.formHandle = session.handle
      trace("auth", "signed in as " & session.did)
      true
    except CatchableError as e:
      setError(e.msg)
      app.connecting = false
      false
  of amBluesky:
    # A remembered broker token is the whole reason to keep one: it buys a
    # fresh web-token without a browser, so a second run connects with no
    # login page at all. Only when there is none does the browser open, and
    # that path does not finish here — `connectNow` is called again from the
    # drain once the handoff lands.
    if app.brokerToken.len == 0:
      app.status = "Waiting for the browser…"
      oa.begin(oa.defaultBroker, app.formHandle)
      return false
    try:
      app.status = "Refreshing your sign-in…"
      adoptTokens(oa.refreshSession(oa.defaultBroker, app.brokerToken))
      true
    except oa.OauthError as e:
      # The broker itself saying no. A token it no longer honours is worse
      # than none — every Connect would spend a round trip failing the same
      # way — so it goes, and the next press opens the browser.
      trace("oauth", "refresh refused: " & e.msg)
      app.brokerToken = ""
      clearSession()
      setError(e.msg)
      app.connecting = false
      false
    except CatchableError as e:
      # Anything else is the network, not the answer: a name that did not
      # resolve, a connection that did not open, a syscall a signal cut
      # short. The token is still good and is kept — throwing it away here
      # meant a dropped wifi or a stray SIGPROF cost the reader their saved
      # sign-in and sent them back to a browser.
      trace("oauth", "refresh failed: " & e.msg)
      setError("Could not reach the broker — " & e.msg)
      app.connecting = false
      false

proc openSocket() =
  ## The connection itself, with whoever we are already settled.
  ##
  ## Split from `connectNow` for the browser handoff: that path has signed in
  ## already, on a token that is single-use, and running `signIn` again would
  ## spend a broker round trip replacing a session it is holding.
  app.connecting = true
  app.status = "Connecting to " & app.formHost & ":" & app.formPort &
               (if app.formTls: " over TLS" else: "") & "…"
  let port = try: parseInt(app.formPort.strip())
             except ValueError: (if app.formTls: 6697 else: 6667)
  tr.open(tr.ConnConfig(host: app.formHost.strip(), port: port,
                        tls: app.formTls))

proc connectNow() =
  if app.formHost.strip().len == 0:
    setError("A server is required."); return
  if app.formNick.strip().len == 0 and app.authMode == amGuest:
    setError("A nickname is required."); return
  app.hasError = false
  if not signIn(): return
  openSocket()

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
  wantFace(m)
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
    clearSession()
    app.loginUrl = ""
    oa.cancel()
    app.status = "Saved session forgotten."

  # --------------------------------------------------------- the connection
  of "connect": connectNow()

  of "cancel", "disconnect":
    rememberRooms(force = true)
    # A browser wait is part of connecting, so Cancel ends it too — otherwise
    # a tab finished ten minutes later would sign in behind the reader.
    oa.cancel()
    app.loginUrl = ""
    # The key goes with the connection, so a reconnect signs with one the
    # server has actually been told about.
    msgsig.forget()
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
      # Forced: a room removed and not written out comes back on the next run
      # as one the reader has already closed.
      rememberRooms(force = true)
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
  # The two that outlive the run are written as they are pressed. There is
  # no Save on this screen and no moment that is obviously the last one — the
  # window closes when it closes.
  of "chat-list.toggle":
    app.hideChatList = not app.hideChatList
    rememberPrefs()
  of "users.toggle":
    # Not remembered; see `restorePrefs`.
    app.showUsers = not app.showUsers
  of "overview.toggle":
    # Not kept: the overview is a way of looking at the moment you are in
    # rather than a preference, and a client that reopened into it would be
    # answering a question nobody asked twice.
    app.overview = not app.overview
  of "join-part.toggle":
    app.hideJoinPart = not app.hideJoinPart
    rememberPrefs()
  of "jump.present":
    app.atPresent = true
    app.jumpTick += 1

  # Where the reader is in the backlog, as the renderer sees it. The core
  # cannot know this on its own: a scroll offset belongs to the thing doing
  # the scrolling, and nothing else here has one.
  #
  # Without these `atPresent` only ever became true — at startup, on opening
  # a room, and on pressing the button — so the button that takes you back to
  # the present was never shown, there being no state in which the reader had
  # left it.
  of "present.left": app.atPresent = false
  of "present.back": app.atPresent = true

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
    app.emojiSearch = ""
    app.emojiGroup = ""
  of "react.close":
    app.reacting = ReactTarget()
    # The search goes with the panel. A picker reopened on another message
    # showing the last one's search is a picker that has to be cleared first.
    app.emojiSearch = ""
    app.emojiGroup = ""

  of "emoji.search.change": app.emojiSearch = value
  of "emoji.group": app.emojiGroup = arg

  of "react.pick":
    # Picking is reacting, and then the panel has done its job.
    if app.reacting.has and arg.len > 0:
      let mid = app.reacting.id
      let m = app.currentRoom.messageById(mid)
      let on = if m.isSome: not m.get.mine(arg, app.formNick) else: true
      var tags = "+draft/react=" & arg & ";+draft/reply=" & mid
      for k, v in mutationTags(if on: "react" else: "unreact",
                               app.current, mid, arg,
                               peerDid(app.currentRoom, app.formNick),
                               nowMs()):
        tags.add ";" & k & "=" & v
      send("@" & tags & " TAGMSG " & app.current)
      app.rooms.updateReaction(app.current, mid, arg, app.formNick, on)
    app.reacting = ReactTarget()
    app.emojiSearch = ""
    app.emojiGroup = ""

  of "react.toggle":
    # `id:emoji`, and the emoji may contain nothing colon-like so one more
    # split is enough.
    let (mid, emoji) = split2(arg)
    if mid.len > 0 and emoji.len > 0:
      let m = app.currentRoom.messageById(mid)
      let on = if m.isSome: not m.get.mine(emoji, app.formNick) else: true
      # Signed where there is a key. freeq answers an unsigned mutation from
      # an account with FAIL TAGMSG SIGNATURE_REQUIRED; a guest has no key and
      # the server asks one for nothing.
      var tags = "+draft/react=" & emoji & ";+draft/reply=" & mid
      for k, v in mutationTags(if on: "react" else: "unreact",
                               app.current, mid, emoji,
                               peerDid(app.currentRoom, app.formNick),
                               nowMs()):
        tags.add ";" & k & "=" & v
      send("@" & tags & " TAGMSG " & app.current)
      app.rooms.updateReaction(app.current, mid, emoji, app.formNick, on)

  of "goto":
    app.jumpTo = arg
    app.highlight = arg

  of "jump.done":
    # The renderer, saying it has scrolled there. The target is taken off
    # again because a `jumpTo` that stayed set would pin the view to that
    # message and take scrolling away from the reader — the highlight stays,
    # since that is what says "this is the one you asked for".
    app.jumpTo = ""

  of "overview.goto":
    # The overview is the one place that moves the reader without their having
    # asked to leave where they were, so it is the one place that owes them
    # the way back. `room:id`.
    let (room, mid) = split2(arg)
    if room.len > 0 and app.rooms.hasKey(room):
      app.overviewReturn = app.current
      openRoom(room)
      app.jumpTo = mid
      app.highlight = mid
      app.overview = false

  of "overview.back":
    if app.overviewReturn.len > 0:
      openRoom(app.overviewReturn)
      app.overviewReturn = ""

  of "profile.open":
    # `nick:actor`, and the actor may be empty — a guest has no identity to
    # fetch, and the panel says so rather than spinning.
    let (nick, argWho) = split2(arg)
    if nick.len > 0:
      # The screen passes what the message itself knows. Where that is
      # nothing — no `account` tag, and a nick that is not handle-shaped —
      # the map filled in by WHO is the answer, and a WHOIS is the last
      # resort for somebody who has since left the room.
      var who = argWho
      if who.len == 0: who = app.dids.getOrDefault(nick, "")
      if who.len == 0: send("WHOIS " & nick)
      app.profileViewing = ProfileView(has: true, nick: nick, actor: who)
      # Blocking, and this is the one place that can afford it: the render
      # path must not, the socket threads have their own work, and the reader
      # pressed a face and is already waiting.
      # A `did:key:` agent has no Bluesky profile to fetch, and the panel
      # says so rather than showing a failure it caused itself.
      if who.len > 0 and not isAgent(who): want(who)

  of "profile.close": app.profileViewing = ProfileView()

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

proc wantFace(m: Message) =
  ## Ask for the face of whoever said this, by the same name the screen will
  ## look it up under.
  ##
  ## That last part is the whole of it. A profile is cached under the actor
  ## `actorFor` returns, and before WHO has answered — or for somebody in a
  ## replayed backlog who is no longer in the room to be answered about —
  ## that is the handle rather than the DID. Asking only when a DID turned up
  ## meant the handle was never asked for, so a face appeared only once the
  ## reader opened the profile by hand, which asks under the same name.
  if m.system or m.frm.len == 0: return
  let did = if m.account.len > 0: m.account
            else: app.dids.getOrDefault(m.frm, "")
  let actor = actorFor(did, m.frm)
  if actor.len > 0: want(actor)

proc note(room: string, m: Message) =
  app.rooms.ensureRoom(room)
  var r = app.rooms[room]
  if seenMessage(r.messages, m.id, m.frm, m.text, app.formNick): return
  r.messages.add m
  r.lastActivity = nowMs()
  app.rooms[room] = r.recount(app.formNick)
  wantFace(m)

proc drain*() =
  # The browser handoff, before the socket: a sign-in that just landed should
  # open the connection in the same frame it arrived, rather than leaving the
  # screen saying "Waiting for the browser…" until the next one.
  while true:
    let (ok, e) = oa.tryEvent()
    if not ok: break
    if e.startsWith("url: "):
      # Shown under "If the browser did not open, visit:" — on a machine with
      # no xdg-open this is the whole of the flow the reader can see.
      app.loginUrl = e[5 .. ^1]
    elif e.startsWith("ok: "):
      oa.finished()
      app.loginUrl = ""
      try:
        adoptTokens(oa.tokensOf(e[4 .. ^1]))
        openSocket()
      except CatchableError as ex:
        setError(ex.msg)
        app.connecting = false
        app.status = "Not connected"
    elif e.startsWith("error: "):
      oa.finished()
      app.loginUrl = ""
      setError(e[7 .. ^1])
      app.connecting = false
      app.status = "Not connected"

  while true:
    let (ok, e) = tr.tryEvent()
    if not ok: break
    trace("status", e)
    if e == "open":
      # The client speaks first in IRC. CAP before registration, the order the
      # server expects. What comes back is answered by `handshake.step`.
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

    # CAP and the SASL exchange inside it, out of `handshake`. Answered before
    # the per-command handling below, because these are the transport's own
    # conversation rather than anything a screen reads.
    if p.command in ["CAP", "AUTHENTICATE", "903", "904", "905", "906"]:
      let st = step(session, caps, p)
      caps = st.caps
      for line in st.send: send(line)
      if p.command == "903":
        app.status = "Signed in as " & app.formNick
        trace("auth", "SASL accepted")
      elif p.command in ["904", "905", "906"]:
        # Refused. Registration carries on as a guest, which is freeq's own
        # behaviour — but it is said, because a silent downgrade is the thing
        # that makes a client look like it signed in when it did not.
        setError("Sign-in refused — connected as a guest.")
        trace("auth", "SASL refused: " & $p.params)
      continue

    case p.command
    of "001":
      app.connecting = false
      app.status = "Connected as " & app.formNick
      app.screen = scChats
      # What the file says we were in, we ask to be in again. The server
      # forgets: it has told this client it is in rooms it is not and left out
      # ones it is, so the saved list is the authority and a room is gone when
      # the reader closes it and not before.
      #
      # DMs are not joined — there is nothing to be in — but they are in the
      # list and come back with their markers all the same.
      var asked = 0
      for name, _ in app.rooms:
        if not dm(name):
          send("JOIN " & name)
          asked.inc
      # A first run has nothing saved. `#test` is where this client has always
      # landed with no list of its own, and stays that until the server's own
      # JOINs are what fills an empty one.
      if asked == 0: send("JOIN #test")

    of "PRIVMSG":
      if p.params.len >= 2:
        let target = p.params[0]
        let who = nickOf(p.prefix)
        # A message to us rather than to a channel belongs in a buffer named
        # for the sender: the target is our own nick and is nobody's room.
        let room = if target.startsWith("#"): target else: who
        # Our own line coming back is the copy we already showed, with the
        # msgid the server gave it — not a new message.
        if who == app.formNick and app.rooms.hasKey(room):
          var r = app.rooms[room]
          let adopted = r.adoptEcho(who, p.params[^1], msgid, at,
                                    if p.hasAccount: p.account else: "")
          if adopted:
            app.rooms[room] = r
            continue

        var m = Message(id: msgid, frm: who, text: p.params[^1], at: at)
        if p.hasAccount: m.account = p.account
        # The picture link out of the text, which is what draws the inline
        # preview. This was hardcoded to "" — assigning a field its own
        # default — so `firstImageUrl` was ported, tested and never called,
        # and no received message ever showed a preview.
        m.imageUrl = firstImageUrl(m.text)
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
        elif not r.users.hasKey(who):
          r.users[who] = ""
        app.rooms[room] = r
        note(room, Message(frm: "*", text: who & " joined " & room,
                           at: at, system: true))

    of "PART", "QUIT":
      let who = nickOf(p.prefix)
      let room = if p.params.len >= 1: p.params[0] else: app.current
      if app.rooms.hasKey(room):
        var r = app.rooms[room]
        r.users.del(who)
        app.rooms[room] = r
        note(room, Message(frm: "*", text: who & " left", at: at,
                           system: true))

    of "353":
      # NAMES, into the PENDING list. It arrives over as many lines as it
      # takes and ends with 366; replacing `users` on each would empty the
      # panel and refill it a name at a time.
      if p.params.len >= 2:
        let room = p.params[^2]
        if app.rooms.hasKey(room):
          var r = app.rooms[room]
          r.namesAcc.withNames(p.params[^1])
          app.rooms[room] = r

    of "366":
      # End of NAMES: the pending list becomes the list.
      if p.params.len >= 1:
        let room = p.params[^2]
        if app.rooms.hasKey(room):
          var r = app.rooms[room]
          if r.namesAcc.len > 0:
            r.users = r.namesAcc
            r.namesAcc.clear()
          app.rooms[room] = r
          # And the only moment this client knows a room has fully arrived.
          #
          # freeq re-joins an authenticated user's channels at registration
          # and leaves the backlog for the client to ask for, so a room that
          # reaches here with an empty buffer has no history coming unless we
          # ask — which is why nothing but new lines ever appeared. It shows
          # up worst on a signed-in connection, which is the one that gets
          # re-joined into rooms it never sent a JOIN for.
          #
          # Only where there is no conversation yet: the replayed lines come
          # back as ordinary PRIVMSGs, and asking again for a room that
          # already has its history is a second copy of it crossing the wire
          # to be discarded by the marker.
          #
          # System lines do not count, and getting that wrong is what made
          # the first version of this do nothing at all: joining a room puts
          # "alice joined #freeq" in the buffer before 366 arrives, so a test
          # for an empty one is a test that never passes.
          if not r.messages.anyIt(not it.system):
            send("CHATHISTORY LATEST " & room & " * " & $historyLimit)
          # And who these people actually are. One WHO answers for the whole
          # room; the alternative is a WHOIS per nick, which is a round trip
          # per face on screen.
          send("WHO " & room)

    of "352":
      # WHO: `<me> <chan> <user> <host> <server> <nick> <flags> :<hops> <real>`
      #
      # freeq puts the full DID in the realname field — `did:plc:…` for an
      # account, `did:key:…` for an agent, and the literal "IRC User" for a
      # guest, who has no identity at all. The hostmask beside it carries
      # `freeq/plc/ngokl2gn`: the first eight characters, which is enough to
      # tell two people apart and not enough to look either of them up.
      if p.params.len >= 8:
        let who = p.params[5]
        let real = p.params[^1]
        let sp = real.find(' ')       # the hop count comes first
        let did = if sp >= 0: real[sp + 1 .. ^1].strip() else: ""
        if did.startsWith("did:"):
          app.dids[who] = did
          # And their face, in the background. A room of twelve is twelve
          # HTTPS round trips, which is affordable on a thread of its own and
          # is not affordable here.
          want(did)

    of "330":
      # WHOIS's `<nick> <account> :is authenticated as`. The same DID by a
      # different road — one nick rather than a room of them.
      if p.params.len >= 3 and p.params[2].startsWith("did:"):
        app.dids[p.params[1]] = p.params[2]
        want(p.params[2])

    of "MODE":
      # A channel MODE, for the letters that change how someone is listed.
      if p.params.len >= 2 and p.params[0].startsWith("#"):
        let room = p.params[0]
        if app.rooms.hasKey(room):
          var r = app.rooms[room]
          r.users.withMode(p.params[1], p.params[2 .. ^1])
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

  # Faces that have come back since the last frame.
  discard collect()

  # A line arriving moves the marker in the room being looked at, and closing
  # the window is not a moment this client gets told about — so the saving
  # happens as it goes, throttled, rather than at an end that may never come.
  rememberRooms()
