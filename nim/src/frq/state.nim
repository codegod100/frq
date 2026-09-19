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

import std/[json, strutils]

type
  AuthMode* = enum
    amGuest = "guest", amBluesky = "bluesky", amAppPassword = "app-password"

  Screen* = enum
    scConnect = "connect", scChats = "chats", scChat = "chat"

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
        formNick: "frq-guest")

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

proc dispatch*(event: JsonNode) =
  let id = event{"id"}.getStr()
  let value = event{"value"}.getStr()

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
    # The spike stops at the edge of I/O: there is no socket here yet, so
    # this reports what it would do. Wiring the real connection in is the
    # `nim/README.md` step about Nim owning the transport, and it does not
    # change anything about the tree or the renderer.
    if app.formHost.strip().len == 0:
      app.error = "A server is required."
      app.hasError = true
    else:
      app.connecting = true
      app.status = "Connecting to " & app.formHost & ":" & app.formPort &
                     (if app.formTls: " over TLS" else: "") & "…"

  of "cancel":
    app.connecting = false
    app.status = "Not connected"

  else: discard
