## The core, for a browser.
##
## `frq_core.nim` is the other one. That file is the only thing that knows
## about C; this is the only thing that knows about JavaScript, and the two
## have the same job: own the state and the screens, and hand a widget tree
## to whatever draws it.
##
## The seam is different because the host is. Across FFI a string is a pointer
## somebody has to free, and `frq_free` says so; here a string is a string.
## What is the same is the shape — a tree out, an event id back — and the
## polling, because the socket is somebody else's and nothing calls in.
##
## The platform modules underneath are chosen by search path: `nim/web/frq`
## comes before `nim/src/frq`, so `frq/conn` is the WebSocket queue rather
## than the socket threads, `frq/store` is localStorage rather than files,
## and so on. The shared code imports the same names either way and never
## learns which host it is on.

import std/[json, strutils, tables]
import frq/[cells, model, reducer, rooms, trace, ui]
import frq/conn as tr
import frq/oauth as oa
import frq/screens/connect as scConnectScreen
import frq/screens/chats as scChatsScreen
import frq/screens/chat as scChatScreen
import frq/screens/settings as scSettingsScreen

proc currentTree(): string =
  ## Whichever screen the state says. `drain` first, so the tree the host gets
  ## is built after every line that had arrived when it asked.
  drain()
  let connected = app.status.startsWith("Connected")
  let node =
    case app.screen
    of scChat: scChatScreen.chatScreen(app, connected)
    of scChats: scChatsScreen.chatsScreen(app, connected)
    of scDiscover: scSettingsScreen.discoverScreen(app)
    of scSettings: scSettingsScreen.settingsScreen(app, connected, true)
    of scConnect: scConnectScreen.connectScreen(app)
  $node.toJson

# ----------------------------------------------------------------- the seam
#
# Everything below is called from JavaScript and nothing else. `exportc` with
# a `frq` prefix rather than Nim's mangled names, so the host can call them by
# the names written here.

proc frqInit(payload: cstring) {.exportc.} =
  ## Once, before anything else. The argument is vestigial: it used to carry
  ## the broker's fragment, and this page is its own OAuth client now — the
  ## host reads the query string, finishes the exchange, and calls
  ## `handoff` or `restoreSession` with a session rather than a payload.
  restore()
  discard payload

proc frqRender(): cstring {.exportc.} = currentTree().cstring
  ## The current screen as a widget tree, in JSON.

proc frqDispatch(event: cstring): cstring {.exportc.} =
  ## Apply an event and answer with the tree it produced — one call, so there
  ## is no window in which the host could draw a state nothing asked for.
  try:
    dispatch(parseJson($event))
  except CatchableError as e:
    trace("dispatch", "!! " & e.msg)
  currentTree().cstring

# --------------------------------------------------------------- the socket
#
# The host owns it. These four are the whole of the transport seam, and they
# are the two the tests already use plus the two a real connection needs.

proc frqWanted(): cstring {.exportc.} =
  ## Where the core is asking to be connected, as JSON, or empty where it is
  ## not asking. The host reads this after a dispatch and opens the socket.
  let cfg = tr.wanted()
  if cfg.host.len == 0: return "".cstring
  ($(%*{"host": cfg.host, "port": cfg.port, "tls": cfg.tls})).cstring

proc frqFeed(line: cstring) {.exportc.} = tr.feed($line)
  ## A line the server sent.

proc frqSocketEvent(e: cstring) {.exportc.} = tr.event($e)
  ## "open", or "close: why", or "error: why".

proc frqTakeOutbound(): cstring {.exportc.} =
  ## Everything the core wants to say, newline-separated, taken as it is read.
  ## One call rather than one per line: a registration is four lines and this
  ## is a crossing each.
  var lines: seq[string]
  while true:
    let (ok, line) = tr.tryOutbound()
    if not ok: break
    lines.add line
  lines.join("\n").cstring

# ----------------------------------------------------------------- sign-in

proc frqBrokerToken(): cstring {.exportc.} = app.brokerToken.cstring
  ## The remembered token, for the host to spend against the broker — `fetch`
  ## is asynchronous, so the core cannot spend it itself.

proc frqHandoff(payload: cstring) {.exportc.} =
  ## A finished sign-in, as JSON from the host — the reader asked for this and
  ## is waiting, so it connects.
  try:
    adoptWebSession(parseJson($payload), thenConnect = true)
  except CatchableError as e:
    oa.failed(e.msg)

proc frqRestoreSession(payload: cstring) {.exportc.} =
  ## A sign-in the host already had, at load. The same fields and a different
  ## meaning: nobody has pressed Connect, so this only puts the name on the
  ## screen and lights the Bluesky tab.
  try:
    adoptWebSession(parseJson($payload), thenConnect = false)
  except CatchableError as e:
    trace("oauth", "ignoring a stored session: " & e.msg)

proc frqWantedSignIn(): cstring {.exportc.} = oa.wantedSignIn().cstring
  ## The handle the core is asking the host to sign in as, or empty.

proc frqNeedProof(): bool {.exportc.} = oa.needProof()
  ## Whether a connection is waiting on a DPoP proof.

proc frqNeedForget(): bool {.exportc.} = oa.needForget()
  ## Whether the reader has asked to be forgotten.

proc frqProofReady(proof: cstring) {.exportc.} = proofReady($proof)
  ## The proof, minted. The last thing a browser connection waits for.

proc frqSignInFailedWith(reason: cstring) {.exportc.} = oa.failed($reason)

proc frqSignInFailed(reason: cstring) {.exportc.} = oa.failed($reason)

# ------------------------------------------------------------------- the rest

proc frqTrace(on: bool) {.exportc.} = trace.enabled = on
  ## Tracing has no environment to be switched on from here, so the console
  ## switches it: `frqTrace(true)`.

proc frqDemo() {.exportc.} =
  ## The same representative room `frq_core.frq_ui_demo` fills, for looking at
  ## the screens without a server.
  app = initState()
  app.formNick = "me"
  app.rooms.ensureRoom("#test")
  var r = app.rooms["#test"]
  r.joined = true
  r.users = {"me": "", "alice": "@", "bob": ""}.toTable
  r.topic = "a room"
  let t0 = 1_700_000_000_000'i64
  r.messages = @[
    Message(id: "1", frm: "*", text: "me joined #test", at: t0, system: true),
    Message(id: "2", frm: "alice", text: "hello there", at: t0 + 1000),
    Message(id: "3", frm: "bob", text: "answering", at: t0 + 2000,
            replyTo: "2"),
    Message(id: "4", frm: "me", text: "a line of my own", at: t0 + 3000)]
  app.rooms["#test"] = r
  app.current = "#test"
  app.screen = scChat
  app.status = "Connected as me"

# The host reaches these by name, so they are put where a name can be reached
# from: a `<script>` tag's globals are the browser's, and a module wrapper's
# are nobody's. One object rather than a scattering of globals, and the same
# object under node, which is what the smoke test drives.
{.emit: """
globalThis.frq = {
  init: frqInit,
  render: frqRender,
  dispatch: frqDispatch,
  wanted: frqWanted,
  feed: frqFeed,
  socketEvent: frqSocketEvent,
  takeOutbound: frqTakeOutbound,
  brokerToken: frqBrokerToken,
  handoff: frqHandoff,
  restoreSession: frqRestoreSession,
  wantedSignIn: frqWantedSignIn,
  needProof: frqNeedProof,
  needForget: frqNeedForget,
  proofReady: frqProofReady,
  signInFailed: frqSignInFailed,
  trace: frqTrace,
  demo: frqDemo,
};
""".}
