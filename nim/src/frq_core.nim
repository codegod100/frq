## The C ABI, and nothing else.
##
## Every exported symbol is here so there is one file to read when asking what
## the Dart side can call. The logic lives under `frq/` in ordinary Nim with
## ordinary Nim types, which is what lets the tests test the rules rather than
## the marshalling.
##
## Two conventions, both of which the bindings in `flutter/src/frq/core/`
## wrap so no call site has to remember them:
##
## * Every returned string is the **caller's** to free, with `frq_free`. Nim's
##   allocator is not Dart's, so a `free()` on this side of the boundary is
##   undefined behaviour rather than a leak you can live with.
## * `frq_init` runs once before anything else. Nim's runtime needs setting up
##   and `--app:lib` does not do it for you on every platform.
##
## Answers that are not a single string come back as JSON. A struct would mean
## both sides agreeing on a memory layout, and a field added later would be a
## version skew that segfaults rather than one that fails; JSON costs a parse
## per call, which is nothing against the network round trip that produced the
## line being parsed.
##
## The UI half of this ABI — `frq_ui_render` and `frq_ui_dispatch` — is Nim
## owning the screens as well as the rules. The screens under it are ported
## from `common/frq/screens/` rather than reimagined, which is the difference
## between this and the experiment that was deleted for being a facsimile.

import std/[json, strutils, tables]
import frq/[ircparse, trace, ui, cells, reducer, model, rooms, eintr]
import frq/conn as tr
import frq/screens/connect as scConnectScreen
import frq/screens/chats as scChatsScreen
import frq/screens/chat as scChatScreen
import frq/screens/settings as scSettingsScreen

proc frq_init*() {.exportc, dynlib.} =
  ## Reads the saved sign-in, and otherwise stays out of the way.
  ##
  ## It used to call `NimMain()`. On Linux `--app:lib` already emits a library
  ## constructor that runs Nim's module initialisers at dlopen, so calling it
  ## again ran every module's top-level code a SECOND time — which for
  ## `conn.nim` meant `outbound.open()` on channels that were already open,
  ## quietly resetting them. The reader thread then drained a different queue
  ## from the one the writer filled, and nothing this client sent ever left.
  ##
  ## So it stayed empty for a long time. What it does now is the one thing
  ## that genuinely belongs before the first frame and cannot go in
  ## `initState`, which is a `func` and touches no disk: restoring the broker
  ## token, so the connect screen opens saying the session is remembered
  ## rather than offering a login page the reader does not need.
  ##
  ## `frq_ui_reset` deliberately does not do this. It is the tests' entry
  ## point, and a suite that picked up whoever is signed in on the machine
  ## running it would pass or fail by accident.
  # Before anything opens a socket. The Dart VM's profiler signals every
  # thread in this process about a thousand times a second, and a syscall
  # interrupted by one fails rather than resuming unless its handler says
  # otherwise — which is why signing in reported `Interrupted system call`.
  restartableSyscalls()
  reducer.restore()

proc dup(s: string): cstring =
  ## A copy of `s` that outlives this call, for the caller to `frq_free`.
  ## `allocShared0` and not `alloc0`: the Dart side may free it from a
  ## different thread than the one that made it.
  let n = s.len
  let p = cast[cstring](allocShared0(n + 1))
  if n > 0:
    copyMem(p, unsafeAddr s[0], n)
  p

proc frq_free*(p: cstring) {.exportc, dynlib.} =
  ## Free what one of the functions below returned. Null is fine.
  if p != nil:
    deallocShared(p)

proc frq_version*(): cstring {.exportc, dynlib.} =
  ## Static storage, deliberately: this one is NOT freed, and is the only
  ## exception to the rule above. It exists so a binding can check at load
  ## time that the library it found is the one it was built against.
  "0.1.0"

# ----------------------------------------------------------------- irc/parse

proc frq_irc_parse_line*(line: cstring): cstring {.exportc, dynlib.} =
  ## An IRC line as JSON: `{raw, tags, account, prefix, command, params}`.
  ##
  ## `tags`, `account` and `prefix` are JSON null where the line carried none,
  ## which is the distinction `frq.irc.parse` draws with nil and every caller
  ## of it depends on — a PRIVMSG from a server with no prefix is not the same
  ## line as one from a nick.
  if line == nil: return dup("null")
  let p = parseLine($line)
  var o = newJObject()
  o["raw"] = %p.raw
  o["tags"] = if p.hasTags: %p.tags else: newJNull()
  o["account"] = if p.hasAccount: %p.account else: newJNull()
  o["prefix"] = if p.hasPrefix: %p.prefix else: newJNull()
  o["command"] = %p.command
  o["params"] = %p.params
  dup($o)

proc frq_irc_tag_value*(tags, key: cstring): cstring {.exportc, dynlib.} =
  ## One tag's value, unescaped — or **null** where the tag is absent or
  ## empty, which IRCv3 says are the same thing. Null and not "" on purpose:
  ## see `tagValue`.
  if tags == nil or key == nil: return nil
  let (v, ok) = tagValue($tags, $key)
  if ok: dup(v) else: nil

proc frq_irc_unescape_tag*(v: cstring): cstring {.exportc, dynlib.} =
  if v == nil: return nil
  dup(unescapeTag($v))

proc frq_irc_escape_tag_value*(v: cstring): cstring {.exportc, dynlib.} =
  if v == nil: return dup("")
  dup(escapeTagValue($v))

proc frq_irc_nick_of*(prefix: cstring): cstring {.exportc, dynlib.} =
  if prefix == nil: return nil
  dup(nickOf($prefix))

# --------------------------------------------------------------- transport
#
# `frq.net`'s three operations, for `frq.net.nim` to install. This is the
# wiring that matters: the existing ClojureDart screens, cells and actions are
# untouched, and only the socket underneath them becomes Nim.
#
# Polled rather than callback-driven, for the reason the UI is: a Dart callback
# invoked from a foreign thread has to be marshalled onto the main isolate, and
# a timer on the Dart side does the same job with no mechanism at all.

proc frq_trace*(topic, msg: cstring) {.exportc, dynlib.} =
  ## Let the Dart side log through the same facility, so one FRQ_TRACE=1 gives
  ## one interleaved story instead of two half-ones in different places.
  if topic != nil and msg != nil:
    trace($topic, $msg)

proc frq_conn_open*(host: cstring, port: cint, tls: cint) {.exportc, dynlib.} =
  if host == nil: return
  tr.open(tr.ConnConfig(host: $host, port: port.int, tls: tls != 0))

proc frq_conn_send*(line: cstring) {.exportc, dynlib.} =
  if line != nil: tr.send($line)

proc frq_conn_close*() {.exportc, dynlib.} =
  tr.close()

proc frq_conn_recv*(): cstring {.exportc, dynlib.} =
  ## The next line, or null when there is none waiting. Never blocks.
  let (ok, line) = tr.tryLine()
  if ok: dup(line) else: nil

proc frq_conn_event*(): cstring {.exportc, dynlib.} =
  ## The next transport event — "open", "close: …", "error: …" — or null.
  let (ok, e) = tr.tryEvent()
  if ok: dup(e) else: nil


# ------------------------------------------------------------------- the UI
#
# Nim owns the state and the screens; Dart owns the pixels. The only things
# crossing are a tree going out and an event id coming back.

proc currentTree(): string =
  ## Whichever screen the state says. `drain` first, so the tree Dart gets is
  ## built after every line that had arrived when it asked — that is the whole
  ## of the polling model, and why there is no callback into Dart.
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

proc frq_ui_render*(): cstring {.exportc, dynlib.} =
  ## The current screen as a widget tree, in JSON.
  ##
  ## Not pure: it drains the socket's queue first, so two calls with no
  ## dispatch between can differ when a line arrived in the gap. That is how
  ## the room fills, and it is why the renderer polls.
  dup(currentTree())

proc frq_ui_dispatch*(event: cstring): cstring {.exportc, dynlib.} =
  ## Apply an event and answer with the tree it produced.
  ##
  ## One call rather than dispatch-then-render, and not to save a crossing: it
  ## makes the pair atomic, so there is no window in which Dart could render a
  ## state nothing asked for.
  if event != nil:
    try:
      dispatch(parseJson($event))
    except JsonParsingError:
      discard
  dup(currentTree())

proc frq_ui_poll*(): cstring {.exportc, dynlib.} =
  ## The tree, for a renderer asking because time passed rather than because
  ## anything happened. Same work as render; named for what the caller means.
  dup(currentTree())

proc frq_ui_wanted_picture*(): cstring {.exportc, dynlib.} =
  ## What an upload needs — `{host, did, channel}` — or empty where none is
  ## wanted. Picking a file and posting it are the host's; this is the core
  ## saying who is asking and where to.
  dup(reducer.wantedPicture())

proc frq_ui_demo*() {.exportc, dynlib.} =
  ## Fill a room with a representative conversation, for a test that wants to
  ## lay the chat screen out without a server.
  ##
  ## It exists because the chat screen is the one a script could not reach: a
  ## GUI on Wayland cannot be clicked, so every automated check stopped at the
  ## room list and the biggest screen in the app went out unlaid-out. The
  ## content is chosen to be awkward on purpose — a long unbroken URL, a very
  ## long word, an image, reactions, a reply, a system line, an edited line —
  ## because a layout bug is about what does not fit.
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
    Message(id: "3", frm: "bob",
            text: "see https://example.com/a/very/long/path/that/will/not/wrap/anywhere/at/all?q=1 for more",
            at: t0 + 2000),
    Message(id: "4", frm: "alice",
            text: "Supercalifragilisticexpialidociousssssssssssssssssssssssssssssssssssss",
            at: t0 + 3000),
    Message(id: "5", frm: "me", text: "a picture", at: t0 + 4000,
            imageUrl: "https://example.com/a.png"),
    Message(id: "6", frm: "bob", text: "answering you", at: t0 + 5000,
            replyTo: "5"),
    Message(id: "7", frm: "me", text: "edited line", at: t0 + 6000,
            edited: true,
            reactions: @[Reaction(emoji: "👍", nicks: @["me", "alice"]),
                         Reaction(emoji: "🎉", nicks: @["bob"])]),
    # A different day, so a heading has to land between them.
    Message(id: "8", frm: "alice", text: "next day", at: t0 + 200_000_000)]
  app.rooms["#test"] = r

  # Somewhere else, because the overview is about every room but this one and
  # with a single room there was nothing for it to show. The test that laid
  # the overview out was laying out "Nothing has happened anywhere else."
  #
  # Awkward on purpose, like the rest: a long bot line that has to be cut,
  # and a short one that must not look different for it.
  app.rooms.ensureRoom("#tasks")
  var other = app.rooms["#tasks"]
  other.joined = true
  other.messages = @[
    Message(id: "o1", frm: "freeq-bot", text: "sandbox-01: I am sandbox 1 of 50.",
            at: t0 + 100_000),
    Message(id: "o2", frm: "freeq-bot",
            text: "**Result**: 50/50 announcements collected in ~12s, and the rest of a sentence that has to be cut somewhere sensible.",
            at: t0 + 200_000)]
  app.rooms["#tasks"] = other

  # A third room, and enough in it that the overview is taller than a phone.
  # Without one nothing here would ever need to scroll, and a test that the
  # overview scrolls would pass on a list that fits.
  app.rooms.ensureRoom("#busy")
  var busy = app.rooms["#busy"]
  busy.joined = true
  for i in 1 .. 12:
    busy.messages.add Message(id: "b" & $i, frm: "carol",
                              text: "line " & $i & " of a long day",
                              at: t0 + 300_000 + i.int64 * 1000)
  app.rooms["#busy"] = busy

  app.current = "#test"
  app.screen = scChat
  app.status = "Connected as me"

proc frq_ui_reset*() {.exportc, dynlib.} =
  tr.close()
  app = initState()
