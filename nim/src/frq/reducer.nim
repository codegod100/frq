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
           profilefetch, edits]
import frq/multiline as ml
import frq/links as lk
import frq/linkfetch as lf
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
  offeredCaps: HashSet[string]
    ## CAP LS fragments accumulated until the server sends the final one.
  landed: bool
    ## Whether this run has already been put back where it left off.
    ##
    ## A flag and not a check of the screen, because 001 arrives more than
    ## once: a dropped socket reconnects and registers again, and a reader
    ## who had deliberately gone out to the overview should not be thrown
    ## back into a room by a network blip. The restore is a thing this run
    ## does once, on the first connection it makes.

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

proc wantPreview(m: Message)
  ## And this for the same reason: a link in our own line gets a card too.

proc openSocket()
  ## And this because a browser sign-in finishes above it: the host answers
  ## asynchronously, and what it answers with is "now you may connect".

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
  multilines: ml.Assembler
    ## The `draft/multiline` batches this connection has open — see
    ## `frq/multiline`.

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

when oa.hostSignsIn:
  # Only where the host is its own OAuth client. On the desktop the broker
  # answers these questions and there is nothing here to compile.

  var webSession: Session
    ## Kept apart from `session`, which `signIn` clears on every Connect —
    ## and on this host the sign-in happened on an earlier page load, so
    ## there is nothing to clear it *from*. Without this the proof arrived
    ## and was fastened to an empty session: no DID, no token, and a SASL
    ## payload that said `pds-oauth` and carried nothing.

  proc adoptWebSession*(j: JsonNode, thenConnect: bool) =
    ## A sign-in the browser host holds, as the core's idea of a session.
    ##
    ## The core never sees the whole of it: the access token, the refresh token
    ## and the key they are bound to stay on the host's side, and what arrives
    ## here is what SASL needs plus the name to put on screen. `thenConnect` is
    ## the difference between coming back from the authorization server — where
    ## the reader asked for this and is waiting — and finding a session in
    ## storage at load, where they have not asked for anything yet.
    webSession = Session(kind: skPdsOauth,
                         did: j{"did"}.getStr(),
                         handle: j{"handle"}.getStr(),
                         accessJwt: j{"accessJwt"}.getStr(),
                         pds: j{"pds"}.getStr(),
                         dpopNonce: j{"dpopNonce"}.getStr(),
                         dpopProof: j{"dpopProof"}.getStr())
    app.hasSession = webSession.accessJwt.len > 0
    app.authMode = amBluesky
    if webSession.handle.len > 0:
      app.formHandle = webSession.handle
      app.formNick = webSession.handle
    trace("oauth", "a browser session for " & webSession.handle)
    if thenConnect and app.hasSession:
      if webSession.dpopProof.len > 0:
        session = webSession
        openSocket()
      else:
        oa.askForProof()

  proc proofReady*(proof: string) =
    ## The proof freeq will present to the PDS on this client's behalf, minted
    ## by the host because minting it is WebCrypto. The last thing a browser
    ## connection waits for.
    if proof.len == 0:
      setError("Could not prove the sign-in; try signing in again.")
      app.connecting = false
      return
    webSession.dpopProof = proof
    session = webSession
    openSocket()

proc setSessionForTest*(did, pds: string) =
  ## A signed-in connection, for a test that is about what follows one.
  session = Session(kind: skPdsOauth, did: did, pds: pds, accessJwt: "tok")

proc wantedPicture*(): string =
  ## What an upload needs, as JSON, or "" when none is wanted.
  ##
  ## Taken as it is read: a file dialog opened twice is a file dialog the
  ## reader has to dismiss twice. The DID is who the upload is filed under —
  ## freeq takes one with a live session, which is why a guest cannot — and
  ## the channel is where it is going.
  if not app.picking: return ""
  app.picking = false
  $(%*{"host": app.formHost.strip(), "did": session.did,
       "channel": app.current})

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
  app.hasSession = saved.brokerToken.len > 0
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
  app.hasSession = true
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
  offeredCaps = initHashSet[string]()
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
    when oa.hostSignsIn:
      # A host that is its own OAuth client. Everything it does is
      # asynchronous — `fetch`, and WebCrypto for the key a DPoP token is
      # bound to — so nothing finishes on this line: either the page leaves
      # for the authorization server, or it mints the proof a connection
      # needs and says so through the drain.
      if not app.hasSession:
        app.status = "Signing in with Bluesky…"
        oa.begin("", app.formHandle)
      else:
        # Per connect, not per sign-in: a proof carries an `iat` and a
        # single-use `jti`, so one kept from the sign-in would be refused by
        # the time a reconnect offered it.
        app.status = "Preparing your sign-in…"
        oa.askForProof()
      return false

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
  # A picture with no words is a message; words with no picture are too.
  let picture = app.attachment.url
  if (text.len == 0 and picture.len == 0) or app.current.len == 0: return
  # The URL goes *in the line*, because that is how a picture travels on IRC:
  # the wire carries text, and every client — this one included — finds the
  # picture by looking for a link in it. `textruns.firstImageUrl` is the other
  # half of this, and it is how every incoming picture is found.
  #
  # It used to be set on the local copy alone, so a picture appeared for the
  # sender and for nobody else.
  let line = if picture.len == 0: text
             elif text.len == 0: picture
             else: text & " " & picture

  if app.editing.has:
    # An edit is a fresh PRIVMSG tagged with what it replaces; the server
    # rewrites the original and echoes the revision back.
    #
    # Signed like every other change to a record already written: freeq keeps
    # the original and says nothing an unsigned edit from an account asked
    # for, so the line would simply never change.
    let mid = app.editing.id
    var tags = "+draft/edit=" & mid
    for k, v in editTags(app.current, mid, line, "",
                         peerDid(app.currentRoom, app.formNick), nowMs()):
      tags.add ";" & k & "=" & v
    send("@" & tags & " PRIVMSG " & app.current & " :" & line)
    # Rewritten on screen now rather than when the echo lands, and — more to
    # the point — *instead* of the local echo below, which would leave the
    # original sitting above a copy of itself with the new wording.
    discard app.rooms.applyEdit(app.current, mid, app.formNick, line, "")
    app.editing = EditTarget()
    app.draft = ""
    app.attachment = Attachment()
    return
  elif app.replyingTo.has:
    send("@+draft/reply=" & app.replyingTo.id & " PRIVMSG " & app.current &
         " :" & line)
    app.replyingTo = ReplyTarget()
  else:
    send("PRIVMSG " & app.current & " :" & line)

  # Echoed locally, because the server does not send your own PRIVMSG back
  # unless echo-message was negotiated — and every client that forgets this
  # looks like it dropped the message.
  var r = app.rooms[app.current]
  var m = Message(frm: app.formNick, text: line, at: nowMs(),
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
    app.hasSession = false
    forgetHostSession()
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
  of "screen.dms": app.screen = scDms
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

  of "window.size":
    # `<width>x<height>`, from whatever is drawing. The core decides what a
    # window that size can hold — whether the room list rides beside the
    # conversation, whether there is a back button — and it cannot measure
    # one: a window is the host's, like a socket or a clock.
    #
    # Nothing sent this until now, so `windowWidth` was zero and `wide` was
    # false on every window there has ever been. The whole side-by-side
    # layout was unreachable, and the button that folds the room list was
    # never drawn — it is only offered on a wide one.
    # In the value where the renderer puts it, or after the colon where a
    # test or a console types it. Both, because the first version read only
    # the id and the test that passed was the one written to match it — the
    # renderer was sending a value nothing looked at.
    let spec = if value.len > 0: value else: arg
    let x = spec.find('x')
    if x > 0:
      let w = try: parseInt(spec[0 ..< x]) except ValueError: 0
      let h = try: parseInt(spec[x + 1 .. ^1]) except ValueError: 0
      if w > 0 and h > 0:
        app.windowWidth = w
        app.windowHeight = h

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

  of "edit.delete":
    # Unsending, which freeq carries as a TAGMSG rather than a message:
    # there is no body, only the id of the line that should stop existing.
    #
    # Signed like a reaction and for the same reason -- it is a mutation of
    # somebody's record, and freeq refuses an unsigned one from an account.
    # `subject` is what is being deleted and there is no emoji, which is
    # exactly the document `chat-signing-vectors.json` freezes under the
    # name `delete`.
    let mid = if arg.len > 0: arg else: app.editing.id
    if mid.len > 0:
      var tags = "+draft/delete=" & mid
      for k, v in mutationTags("delete", app.current, mid, "",
                               peerDid(app.currentRoom, app.formNick),
                               nowMs()):
        tags.add ";" & k & "=" & v
      send("@" & tags & " TAGMSG " & app.current)
      # Taken off the screen now rather than when the echo lands. The server
      # relays the TAGMSG back and `TAGMSG` below would remove it again, to
      # no effect -- but a reader who has just pressed Delete should not
      # watch the line sit there while a round trip happens.
      discard app.rooms.applyDelete(app.current, mid)
    app.editing = EditTarget()
    app.draft = ""

  of "image.pick":
    # Picking a file and uploading it are both the host's: a file dialog is
    # the platform's, and so is a multipart POST. The core says who is asking
    # and where to, and the host answers with a URL.
    #
    # This had no handler at all, so the button traced "no handler" and did
    # nothing — which is what "the image upload icon is not working" was.
    if session.did.len == 0:
      setError("Sign in to send a picture — an upload is filed under your " &
               "account.")
    elif app.current.len == 0:
      setError("Open a conversation to send a picture to.")
    else:
      app.picking = true
      app.status = "Choosing a picture…"

  of "attachment.ready":
    # The URL freeq serves it back at. Held apart from the draft rather than
    # pasted into it — see `cells.Attachment` — and put on the line by
    # `sendDraft` when the message goes.
    app.picking = false
    if arg.len > 0:
      app.attachment = Attachment(has: true, path: arg, url: arg,
                                  status: usReady)
      app.status = "Picture attached"

  of "attachment.failed":
    app.picking = false
    setError(if arg.len > 0: arg else: "That picture could not be sent.")

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

proc notePreviewTags(tags: string) =
  ## A preview the sender sent with their line, into the cache.
  ##
  ## freeq carries one as `+freeq.at/link-*`, signed with the message the way
  ## an attachment is. Where it is there it is the better answer than asking
  ## the server to go and look: it costs no round trip, and it is what the
  ## author said the link was rather than what the page says about itself
  ## today. `want` finds the URL already known and asks nothing.
  let (url, hasUrl) = tagValue(tags, "+freeq.at/link-url")
  if not hasUrl or not lk.previewable(url) or lk.known(url): return
  let (title, _) = tagValue(tags, "+freeq.at/link-title")
  let (desc, _) = tagValue(tags, "+freeq.at/link-desc")
  let (image, _) = tagValue(tags, "+freeq.at/link-image")
  if title.len == 0 and image.len == 0: return
  lk.remember(url, lk.Preview(status: lk.lsReady, title: title,
                              description: desc, image: image))

proc taskEvent(tags: string): TaskEvent =
  ## The structured half of a FreeQ action.  It travels as a TAGMSG and its
  ## visible companion names this event through `+freeq.at/ref`.
  ##
  ## Only `handoff` is a task card for now. Other act kinds remain ordinary
  ## messages until they have their own reader-facing treatment.
  let (kind, hasKind) = tagValue(tags, "+freeq.at/act")
  let (verb, hasVerb) = tagValue(tags, "+freeq.at/act-verb")
  let (eventId, hasEventId) = tagValue(tags, "+freeq.at/eventid")
  if not hasKind or kind != "handoff" or not hasVerb or not hasEventId: return
  let (actId, hasActId) = tagValue(tags, "+freeq.at/act-id")
  result.id = eventId
  result.taskId = if hasActId: actId else: eventId
  result.kind = kind
  result.verb = verb
  (result.title, _) = tagValue(tags, "+freeq.at/act-title")
  (result.offeredTo, _) = tagValue(tags, "+freeq.at/act-to")
  (result.caps, _) = tagValue(tags, "+freeq.at/act-caps")
  (result.note, _) = tagValue(tags, "+freeq.at/act-note")
  (result.context, _) = tagValue(tags, "+freeq.at/act-ctx")

func ulidMs(id: string): int64 =
  ## The millisecond a ULID was minted in, or -1 for an id that is not one.
  const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  if id.len != 26: return -1
  for c in id[0 ..< 10]:
    let digit = crockford.find(c)
    if digit < 0: return -1
    result = result * 32 + digit

func companionFits(task: TaskEvent, m: Message): bool =
  ## Whether `m` could be the line its sender posted beside `task`.
  ##
  ## freeq's companion names the task (`+freeq.at/ref`), never the event, so
  ## every later move on a task — and any other line that mentions it — names
  ## the same thing. The reference client tells them apart the way this does:
  ## the same sender (by DID where both sides carry one), and written in the
  ## event's own second or the one after. An event id that is not a ULID
  ## carries no time and is judged on the sender alone.
  let sameSender =
    if task.did.len > 0 and m.account.len > 0: task.did == m.account
    else: cmpIgnoreCase(task.frm, m.frm) == 0
  if not sameSender: return false
  let minted = ulidMs(task.id)
  if minted < 0 or m.at <= 0: return true
  let gap = m.at div 1000 - minted div 1000
  gap >= 0 and gap <= 1

proc pairTask(room: Room, task: TaskEvent, m: var Message) =
  var task = task
  if task.title.len == 0:
    task.title = room.taskTitles.getOrDefault(task.taskId, "")
  m.task = task

proc attachTask(tags: string, room: var Room, m: var Message) =
  ## Turn a companion line into a card only when this client has received the
  ## matching typed action. Text that merely resembles a status stays chat.
  ##
  ## An event has at most one companion and is forgotten once it has it.
  ## Keyed by task rather than event, because that is all the line names:
  ## this used to look the reference up as an event id, which is only true
  ## of a task's opener — so any line carrying the reference became another
  ## copy of the offer, and no later move on the task was ever a card.
  let (taskRef, hasRef) = tagValue(tags, "+freeq.at/ref")
  if not hasRef or taskRef.len == 0: return
  m.taskRef = taskRef
  if not room.taskEvents.hasKey(taskRef): return
  var waiting = room.taskEvents[taskRef]
  for i, task in waiting:
    if companionFits(task, m):
      room.pairTask(task, m)
      waiting.delete(i)
      if waiting.len == 0: room.taskEvents.del(taskRef)
      else: room.taskEvents[taskRef] = waiting
      return

proc holdTask(room: var Room, task: TaskEvent) =
  ## An event just arrived. Its companion may already be here — a replay
  ## orders by the second, and the line and its event share one — so give it
  ## to the first unpaired line that fits, and otherwise wait for one.
  if task.title.len > 0: room.taskTitles[task.taskId] = task.title
  for m in room.messages.mitems:
    if m.taskRef == task.taskId and m.task.id.len == 0 and
       companionFits(task, m):
      room.pairTask(task, m)
      return
  room.taskEvents.mgetOrPut(task.taskId, @[]).add task

proc wantPreview(m: Message) =
  ## Ask what is at the end of the link in this line, if it has one.
  ##
  ## Here rather than in the screen because a screen must not fetch, and here
  ## rather than at the PRIVMSG because a line arrives by three roads — said,
  ## replayed, or echoed back — and `note` is the one they all pass through.
  if m.system: return
  let url = firstPreviewUrl(m.text)
  if url.len > 0: lf.want(app.formHost, url)

proc note(room: string, m: Message) =
  # A wire record with no words is not a chat line.  In particular, some
  # servers send empty NOTICEs around history batches; retaining them gives
  # the screen a day divider and no corresponding message.
  if m.text.strip.len == 0: return
  app.rooms.ensureRoom(room)
  var r = app.rooms[room]
  # Before the duplicate check: a replay of lines we already hold is still a
  # replay, and still means the server has sent this room's backlog.
  if not m.system: r.heard = true
  if seenMessage(r.messages, m.id, m.frm, m.text, app.formNick):
    app.rooms[room] = r
    return
  # A history replay may arrive after live traffic.  Preserve the server's
  # chronology instead of the socket's arrival order, so an old replay does
  # not become the apparent newest line in the room.
  var insertAt = r.messages.len
  if m.at > 0:
    for i in countdown(r.messages.high, 0):
      if r.messages[i].at <= m.at:
        insertAt = i + 1
        break
      insertAt = i
  r.messages.insert(m, insertAt)
  r.lastActivity = nowMs()
  app.rooms[room] = r.recount(app.formNick)
  wantFace(m)
  wantPreview(m)

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
      caps = initHashSet[string]()
      offeredCaps = initHashSet[string]()
      multilines.reset()
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
    # A multiline batch is held until it closes and comes out as one
    # message; at most one line comes out of any line that goes in.
    let whole = multilines.feed(parseLine(line))
    if whole.len == 0: continue
    let p = whole[0]

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
      let st = step(session, caps, offeredCaps, p)
      caps = st.caps
      offeredCaps = st.offered
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

      # Back into the room the reader was last in, rather than the list of
      # them. The name is not stored separately: `accessed` is already saved
      # per room and already means "when this was last opened", so the most
      # recent of them is the answer and there is no second thing to keep in
      # step with the first.
      #
      # Only on this run's first connection — see `landed`. And only where
      # there is one: a first run has a list of rooms it has never opened,
      # and lands on the overview as it always did.
      if not landed:
        landed = true
        let last = app.rooms.lastVisited
        if last.len > 0: openRoom(last)

    of "PRIVMSG":
      if p.params.len >= 2:
        let target = p.params[0]
        let who = nickOf(p.prefix)
        # A message to us rather than to a channel belongs in a buffer named
        # for the sender: the target is our own nick and is nobody's room.
        let room = if target.startsWith("#"): target else: who
        # A revision is not a new line: it replaces the one it names, under
        # that line's own id — never the revision's own wire msgid, which
        # nothing else refers to. Before the echo check below, because our
        # own edit comes back this way too and is not a new message either.
        let (editOf, isEdit) = block:
          let (v, ok2) = tagValue(p.tags, "+edit")
          if ok2: (v, true) else: tagValue(p.tags, "+draft/edit")
        if isEdit and editOf.len > 0:
          if app.rooms.applyEdit(room, editOf, who, p.params[^1], msgid) ==
             erAbsent:
            # The original is older than the backlog we hold, so show the
            # current wording rather than dropping what was said.
            var m = Message(id: editOf, frm: who, text: p.params[^1], at: at,
                            edited: true)
            if p.hasAccount: m.account = p.account
            m.imageUrl = firstImageUrl(m.text)
            let (rep, hasRep) = block:
              let (v, ok2) = tagValue(p.tags, "+reply")
              if ok2: (v, true) else: tagValue(p.tags, "+draft/reply")
            if hasRep: m.replyTo = rep
            app.rooms.ensureRoom(room)
            attachTask(p.tags, app.rooms[room], m)
            notePreviewTags(p.tags)
            note(room, m)
          continue

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
        let (rep, hasRep) = block:
          let (v, ok2) = tagValue(p.tags, "+reply")
          if ok2: (v, true) else: tagValue(p.tags, "+draft/reply")
        if hasRep: m.replyTo = rep
        let (tally, hasTally) = tagValue(p.tags, "+freeq.at/reacts")
        if hasTally: m.reactions = parseTally(tally)
        # A replay sends one row per message, carrying the current text and
        # no `+draft/edit` to say it is not the original. This tag is the
        # only trace, so a message can arrive already edited.
        let (wasEdited, hasEdited) = tagValue(p.tags, "+freeq.at/edited")
        if hasEdited and wasEdited != "0": m.edited = true
        app.rooms.ensureRoom(room)
        attachTask(p.tags, app.rooms[room], m)
        notePreviewTags(p.tags)
        note(room, m)

    of "TAGMSG":
      # A message with tags and nothing said. freeq carries deletes on one,
      # and relays it to the channel -- so this arrives both for our own
      # delete and for everybody else's, including an op's.
      #
      # Reactions ride a TAGMSG too and are not handled here: they arrive
      # again as a tally on the next CHATHISTORY, which is the only reason
      # their absence has gone unnoticed. A delete has no such second
      # chance, because the whole point is that the line stops being sent.
      if p.params.len >= 1:
        let target = p.params[0]
        let room = if target.startsWith("#"): target else: nickOf(p.prefix)
        let task = taskEvent(p.tags)
        if task.id.len > 0:
          app.rooms.ensureRoom(room)
          var task = task
          task.frm = nickOf(p.prefix)
          if p.hasAccount: task.did = p.account
          var r = app.rooms[room]
          r.holdTask(task)
          app.rooms[room] = r
        let (gone, isDelete) = tagValue(p.tags, "+draft/delete")
        if isDelete and gone.len > 0:
          discard app.rooms.applyDelete(room, gone)

    of "JOIN":
      if p.params.len >= 1:
        let room = p.params[0]
        app.rooms.ensureRoom(room)
        var r = app.rooms[room]
        let who = nickOf(p.prefix)
        if who == app.formNick:
          r.joined = true
          r.joining = false
          # Whatever follows before 366 is this join's backlog, if any.
          r.heard = false
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

    of "NICK":
      # Somebody is called something else now — including us.
      #
      # Our own rename is the server settling what we are called, and it is
      # the usual way the nick on screen becomes the real one: freeq hands a
      # guest a name of its choosing, and settles a signed-in connection on
      # the account's. Without this the client goes on calling itself what it
      # asked to be called, which is how a reader signs in with Bluesky and
      # finds they are still `frq-guest` — and why every "is this mine?" test
      # on a line then says no.
      let who = nickOf(p.prefix)
      let fresh = if p.params.len >= 1: p.params[^1] else: ""
      if who.len > 0 and fresh.len > 0:
        for name in toSeq(app.rooms.keys):
          var r = app.rooms[name]
          if r.users.renameUser(who, fresh):
            app.rooms[name] = r
        if who == app.formNick:
          app.formNick = fresh
          if app.status.startsWith("Connected") or
             app.status.startsWith("Signed in"):
            app.status = "Connected as " & fresh
          trace("auth", "the server calls us " & fresh)

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
          # Only where this join brought no conversation with it: a real
          # JOIN replays the backlog as ordinary PRIVMSGs before NAMES, and
          # asking again is a second copy of it crossing the wire to be
          # discarded by the marker.
          #
          # Not "where the buffer is empty", which is what this was, and
          # which is why a room stopped showing recent messages. A socket
          # that drops and comes back keeps this run's buffer, and freeq
          # answers the reconnect by reclaiming the ghost session — JOIN and
          # NAMES, no backlog, and our own JOIN then ignored as a double. The
          # buffer held the lines from before the drop, so nothing was asked
          # for and everything said while we were away never arrived.
          #
          # System lines do not count, and getting that wrong is what made
          # the first version of this do nothing at all: joining a room puts
          # "alice joined #freeq" in the buffer before 366 arrives.
          if not r.heard:
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

  # Faces that have come back since the last frame, and previews.
  discard profilefetch.collect()
  discard lf.collect()

  # A line arriving moves the marker in the room being looked at, and closing
  # the window is not a moment this client gets told about — so the saving
  # happens as it goes, throttled, rather than at an end that may never come.
  rememberRooms()
