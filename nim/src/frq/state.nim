## The app state, and the events that move it.
##
## This is `frq.cells` and `frq.actions` as one module, and merging them is
## the point rather than a shortcut: in the Clojure the cells are atoms a
## screen derefs and the actions are a table the host installs, and the split
## exists because the host and the screens were compiled separately. Here the
## state is Nim's, the reducer is Nim's, and there is no host to install
## anything — Dart sends an event id and gets a new tree back.
##
## Which makes the shape Elm's, and deliberately so. A screen is a pure
## function of this record; an event is the only way it changes; nothing else
## crosses the boundary. That is what lets the renderer stay dumb.

import std/[json, os, strutils]
import trace, ircparse, irc

type
  AuthMode* = enum
    amGuest = "guest", amBluesky = "bluesky", amAppPassword = "app-password"

  Screen* = enum
    scConnect = "connect", scChats = "chats", scChat = "chat"

  Message* = object
    frm*: string
    text*: string

  State* = object
    screen*: Screen
    status*: string
    error*: string
    hasError*: bool
    connecting*: bool

    # The connect form.
    authMode*: AuthMode
    formHost*: string
    formPort*: string
    formTls*: bool
    formNick*: string
    formHandle*: string
    formAppPassword*: string
    brokerToken*: string

    # The one channel the spike knows about, and its backlog.
    channel*: string
    messages*: seq[Message]
    draft*: string
    registered*: bool

const
  defaultHost* = "irc.freeq.at"
  defaultPort* = "6697"

func initState*(): State =
  State(screen: scConnect,
        status: "Not connected",
        authMode: amGuest,
        formHost: defaultHost,
        formPort: defaultPort,
        formTls: true,
        formNick: "frq-guest",
        channel: "#test")

var app* = initState()
  ## The one mutable thing in the spike. Named `app` and not `state` because
  ## `state` is ambiguous against unittest's own in a test module, which is
  ## the sort of collision worth losing five characters to avoid.

# ------------------------------------------------------------------ events
#
# One entry point, and a string id rather than an enum, because the ids are
# written into the tree that crosses the boundary and an enum on this side
# would be a number Dart had to agree with. A name that does not match
# anything is ignored rather than fatal: a stale tree held by the renderer for
# one frame after a state change is a normal race, not an error.

proc summary(s: State): string =
  ## What is worth seeing in a trace line, which is not every field: the
  ## password is deliberately absent, and the token is reported as present or
  ## not rather than printed. A trace that cannot be pasted into a bug report
  ## is a trace people turn off.
  "screen=" & $s.screen & " mode=" & $s.authMode &
  " host=" & s.formHost & ":" & s.formPort &
  (if s.formTls: "+tls" else: "") &
  " connecting=" & $s.connecting &
  (if s.hasError: " error=" & s.error.escape else: "") &
  (if s.brokerToken.len > 0: " token=yes" else: "")

proc dispatch*(event: JsonNode) =
  let id = event{"id"}.getStr()
  let value = event{"value"}.getStr()

  traced "dispatch": "→ " & id &
    (if value.len > 0: " value=" & value.escape else: "") &
    "  before: " & app.summary

  case id
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
    # The port follows the tick, exactly as the Clojure's :on-toggled does.
    app.formPort = if app.formTls: "6697" else: "6667"

  of "error.dismiss":
    app.error = ""
    app.hasError = false

  of "connect":
    if app.formHost.strip().len == 0:
      app.error = "A server is required."
      app.hasError = true
    elif app.formNick.strip().len == 0:
      app.error = "A nickname is required."
      app.hasError = true
    else:
      app.connecting = true
      app.status = "Connecting to " & app.formHost & ":" & app.formPort &
                   (if app.formTls: " over TLS" else: "") & "…"
      irc.start(ConnConfig(host: app.formHost.strip(),
                           port: try: parseInt(app.formPort.strip())
                                 except ValueError: (if app.formTls: 6697 else: 6667),
                           tls: app.formTls,
                           nick: app.formNick.strip()))

  of "cancel", "disconnect":
    irc.stop()
    app.connecting = false
    app.registered = false
    app.screen = scConnect
    app.status = "Not connected"

  of "draft.change": app.draft = value

  of "send":
    # The point of the spike: a line the user typed, out to #test.
    let text = app.draft.strip()
    if text.len > 0 and app.registered:
      irc.send("PRIVMSG " & app.channel & " :" & text)
      # Echoed locally, because IRC does not send your own PRIVMSG back to
      # you. Every client does this and every client that forgets looks like
      # it dropped the message.
      app.messages.add Message(frm: app.formNick, text: text)
      app.draft = ""

  else:
    trace("dispatch", "!! no handler for " & id.escape & " — ignored")

  traced "dispatch": "  after:  " & app.summary

# ------------------------------------------------------------------- drain
#
# Called on the UI thread before a render, so the tree Dart receives is built
# after every line that had arrived when it asked. This is where the socket
# thread's output becomes state; nothing else touches it.

proc drain*() =
  while true:
    let (ok, s) = tryRecvStatus()
    if not ok: break
    trace("status", s)
    if s == "connecting":
      app.status = "Connecting…"
    elif s.startsWith("failed:"):
      app.connecting = false
      app.registered = false
      app.error = s[7 .. ^1].strip()
      app.hasError = true
      app.status = "Not connected"
    elif s == "closed":
      app.connecting = false
      app.registered = false
      app.status = "Disconnected"

  while true:
    let (ok, line) = tryRecvLine()
    if not ok: break
    let p = parseLine(line)
    case p.command
    of "001":
      # Welcome: registration is done, so join the channel and show the room.
      app.registered = true
      app.connecting = false
      app.status = "Connected as " & app.formNick
      app.screen = scChat
      irc.send("JOIN " & app.channel)
      trace("irc", "registered; joining " & app.channel)

    of "PRIVMSG":
      if p.params.len >= 2:
        app.messages.add Message(frm: nickOf(p.prefix), text: p.params[^1])

    of "JOIN":
      if p.params.len >= 1:
        app.messages.add Message(frm: "*", text: nickOf(p.prefix) & " joined " & p.params[0])

    of "PART", "QUIT":
      app.messages.add Message(frm: "*", text: nickOf(p.prefix) & " left")

    of "NOTICE":
      if p.params.len >= 2:
        app.messages.add Message(frm: "notice", text: p.params[^1])

    of "432", "433", "436":
      # Nickname refused. Worth naming rather than showing a numeric: this is
      # the most likely way a guest connect fails and the least obvious.
      app.error = "That nickname is taken or invalid."
      app.hasError = true
      app.connecting = false

    else:
      # Everything else is the MOTD and friends — traced, not shown.
      trace("irc.skip", p.command & " " & $p.params)


# -------------------------------------------------------------- autoconnect
#
# `FRQ_AUTOCONNECT=1` presses Connect as soon as the first screen is asked
# for. In the same spirit as FRQ_TRACE and for the same reason: a GUI on
# Wayland cannot be clicked from a script, so without this the only way to
# check that the window connects is to sit in front of it. It also makes
# `just nim-spike` a one-command demo.
#
# `FRQ_NICK` overrides the nickname, because two runs with the same one
# collide on the server and the second is refused.

var autoconnectDone = false

proc maybeAutoconnect*() =
  if autoconnectDone: return
  autoconnectDone = true
  let want = getEnv("FRQ_AUTOCONNECT")
  if want.len == 0 or want == "0": return
  let nick = getEnv("FRQ_NICK")
  if nick.len > 0: app.formNick = nick
  trace("auto", "FRQ_AUTOCONNECT set — connecting as " & app.formNick)
  dispatch(%*{"id": "connect"})
