## The screens, as pure functions of the state.
##
## These are the tests the ClojureDart screens never had and could not easily
## have: a screen there is hiccup over cells a host installs, so exercising one
## means standing up a host. Here it is a function from a record to a tree.

import std/[json, sequtils, strutils, tables, unicode, unittest]
import frq/[ui, cells, model]
import frq/screens/connect as cs
import frq/screens/settings as ss
import frq/screens/chat as cht
import frq/[rooms]

proc find*(node: Node, tag: string): seq[Node] =
  if node.isNil: return
  if node.tag == tag: result.add node
  for c in node.children: result.add c.find(tag)

proc labels(node: Node, tag: string): seq[string] =
  node.find(tag).mapIt(it.props{"label"}.getStr())

proc keys(node: Node, tag: string): seq[string] =
  node.find(tag).mapIt(it.props{"key"}.getStr())

suite "the connect screen":
  setup:
    var s = initState()

  test "is a page with the title and the transport note":
    let t = cs.connectScreen(s)
    check t.tag == "page"
    check "frq" in t.labels("title")
    check cs.transportNote in t.labels("dim-label")

  test "the fields holding an identifier ask to be taken as typed":
    # A phone keyboard puts a space after a full stop, because a full stop
    # ends a sentence -- and is also the middle of `alice.bsky.social`. The
    # compose box is prose and is left alone; these are not.
    for mode in [amGuest, amBluesky, amAppPassword]:
      var f = initState()
      f.authMode = mode
      let fields = cs.connectScreen(f).find("entry")
      check fields.len > 0
      for e in fields:
        check e.props{"verbatim"}.getBool() == true

  test "is pure — twice with no change is the same tree":
    check $cs.connectScreen(s).toJson == $cs.connectScreen(s).toJson

  test "guest is the default, and shows a nick field":
    let t = cs.connectScreen(s)
    check "Connect as guest" in t.labels("title-2")
    check "nick" in t.keys("entry")
    check "handle" notin t.keys("entry")

  test "bluesky shows a handle and its own copy":
    s.authMode = amBluesky
    let t = cs.connectScreen(s)
    check "Sign in with Bluesky" in t.labels("title-2")
    check "handle" in t.keys("entry")
    check "nick" notin t.keys("entry")

  test "and says what Connect will actually do":
    # This used to assert the opposite — that the screen admitted the broker
    # flow was not wired up — which was the honest copy while it was not.
    # A window opening on its own is alarming without a line saying it will.
    s.authMode = amBluesky
    let dim = cs.connectScreen(s).labels("dim-label")
    check dim.anyIt("opens your browser" in it)
    check dim.anyIt("never reaches this app" in it)

  test "app-password asks for both, and says where to make one":
    s.authMode = amAppPassword
    let t = cs.connectScreen(s)
    check "handle" in t.keys("entry")
    check "app-password" in t.keys("entry")
    check t.labels("dim-label").anyIt("App Passwords" in it)

  test "a remembered session offers to be forgotten, and only then":
    s.authMode = amBluesky
    check "Forget saved session" notin cs.connectScreen(s).labels("button")
    s.brokerToken = "tok"
    check "Forget saved session" in cs.connectScreen(s).labels("button")

  test "the login URL is shown while the browser is open":
    s.authMode = amBluesky
    s.loginUrl = "https://auth.freeq.at/x"
    let t = cs.connectScreen(s)
    check "https://auth.freeq.at/x" in t.labels("label")

  test "the error note keeps its place whether or not there is an error":
    # The bug the stable wrapper exists for: a renderer matching children by
    # position would patch the header into a card when the error appeared.
    let before = cs.connectScreen(s).children.mapIt(it.tag)
    s.hasError = true
    s.error = "nope"
    check cs.connectScreen(s).children.mapIt(it.tag) == before
    check "Dismiss" in cs.connectScreen(s).labels("button")

  test "the remembered and login-url wrappers hold their place too":
    s.authMode = amBluesky
    let bare = cs.connectScreen(s)
    s.brokerToken = "tok"
    s.loginUrl = "https://x"
    check cs.connectScreen(s).keys("vbox").filterIt(it.len > 0) ==
          bare.keys("vbox").filterIt(it.len > 0)

  test "connecting swaps Connect for a spinner and a way out":
    s.connecting = true
    let t = cs.connectScreen(s)
    check t.find("spinner").len == 1
    check "Connect" notin t.labels("button")
    check "Cancel" in t.labels("button")

suite "discover":
  setup:
    var s = initState()

  test "lists the popular channels with their blurbs":
    let t = ss.discoverScreen(s)
    check t.labels("title-2") == popularChannels.mapIt(it[0])
    check "#general" in t.keys("card")

  test "offers Join for a room we are not in and Open for one we are":
    check ss.discoverScreen(s).labels("button").countIt(it == "Join") ==
          popularChannels.len
    var r = initRoom("#test"); r.joined = true
    s.rooms["#test"] = r
    let t = ss.discoverScreen(s)
    check "Open" in t.labels("button")
    check t.labels("button").countIt(it == "Join") == popularChannels.len - 1

  test "the tab bar is under it, with Discover selected":
    let t = ss.discoverScreen(s)
    s.screen = scDiscover
    let sel = ss.discoverScreen(s).find("button")
      .filterIt(it.props{"kind"}.getStr() == "primary")
      .mapIt(it.props{"label"}.getStr())
    check "Discover" in sel
    check t.find("scroll").len == 1

suite "settings":
  setup:
    var s = initState()

  test "a guest is told so":
    check "Guest — not signed in." in
      ss.settingsScreen(s, connected = false, desktop = true).labels("dim-label")

  test "a signed-in handle is shown, and can be forgotten":
    s.formHandle = "alice.bsky.social"
    s.brokerToken = "tok"
    let t = ss.settingsScreen(s, connected = true, desktop = true)
    check "alice.bsky.social" in t.labels("label")
    check "Forget Bluesky session" in t.labels("button")

  test "Disconnect when connected, Back to connect when not":
    check "Disconnect" in
      ss.settingsScreen(s, connected = true, desktop = true).labels("button")
    check "Back to connect" in
      ss.settingsScreen(s, connected = false, desktop = true).labels("button")

  test "Quit only where there is a window to quit":
    check "Quit" in
      ss.settingsScreen(s, connected = false, desktop = true).labels("button")
    check "Quit" notin
      ss.settingsScreen(s, connected = false, desktop = false).labels("button")

  test "the join/part switch reflects the cell":
    let off = ss.settingsScreen(s, false, true).find("checkbutton")[0]
    check not off.props{"active"}.getBool()
    s.hideJoinPart = true
    let on = ss.settingsScreen(s, false, true).find("checkbutton")[0]
    check on.props{"active"}.getBool()

  test "the status line is live only when connected":
    check ss.settingsScreen(s, true, true).find("status")[0]
            .props{"live"}.getBool()
    check not ss.settingsScreen(s, false, true).find("status")[0]
            .props{"live"}.getBool()

import frq/screens/chats as ch

suite "previewLine":
  test "collapses whitespace so a card reads as one line":
    check ch.previewLine("a\n  b\tc") == "a b c"
  test "truncates a pasted script rather than growing the card":
    let long = "x".repeat(200)
    check ch.previewLine(long).runeLen == 60
    check ch.previewLine(long).endsWith("…")

  test "truncates by character, not by byte":
    # A byte slice at 59 lands inside a multi-byte character and produces
    # mojibake where an ellipsis was wanted. The first draft did exactly that.
    let emoji = "😀".repeat(100)
    let got = ch.previewLine(emoji)
    check got.runeLen == 60
    check got.validateUtf8 == -1
  test "leaves a short line alone":
    check ch.previewLine("hello there") == "hello there"

suite "the chats screen":
  setup:
    var s = initState()
    var r = initRoom("#test")
    r.joined = true
    r.messages = @[Message(frm: "alice", text: "hello")]
    s.rooms["#test"] = r

  test "an empty list says so instead of showing nothing":
    var empty = initState()
    check "No conversations yet — join a channel." in
      ch.chatsScreen(empty, false).labels("dim-label")

  test "a room is a card with its name and last line":
    let t = ch.chatsScreen(s, true)
    check "#test" in t.labels("title-2")
    check "alice: hello" in t.labels("dim-label")

  test "the title says who we are when connected":
    check "Logged in as frq-guest" in ch.chatsScreen(s, true).labels("title")
    check "Chats" in ch.chatsScreen(s, false).labels("title")

  test "an unread count shows, with a mention marked differently":
    var u = s.rooms["#test"]
    u.unread = 3
    s.rooms["#test"] = u
    check "● 3" in ch.chatsScreen(s, true).labels("label")
    u.mention = true
    s.rooms["#test"] = u
    check "◆ @ 3" in ch.chatsScreen(s, true).labels("label")

  test "a channel we are not in is badged, a DM never is":
    var away = s.rooms["#test"]
    away.joined = false
    s.rooms["#test"] = away
    check "not joined" in ch.chatsScreen(s, true).labels("status")
    var dmr = initRoom("alice")
    s.rooms["alice"] = dmr
    # Still only the one badge: a DM has nothing to join.
    check ch.chatsScreen(s, true).labels("status").countIt(it == "not joined") == 1

  test "the button says Message for a nick and Join for a channel":
    s.joinInput = "#room"
    check "Join" in ch.chatsScreen(s, true).labels("button")
    s.joinInput = "@alice"
    check "Message" in ch.chatsScreen(s, true).labels("button")

  test "the search box offers a clear only when there is something to clear":
    check "✕" notin ch.chatsScreen(s, true).labels("button")
    s.search = "te"
    check "✕" in ch.chatsScreen(s, true).labels("button")

  test "search filters the list":
    s.rooms["#other"] = initRoom("#other")
    s.search = "oth"
    let names = ch.chatsScreen(s, true).labels("title-2")
    check names == @["#other"]

suite "the chat screen's panes":
  setup:
    var s = initState()
    s.formNick = "me"
    s.windowWidth = wideWidth      # both panes on screen
    s.rooms.ensureRoom("#test")
    var r = s.rooms["#test"]
    r.joined = true
    r.users = {"me": "", "alice": "@"}.toTable
    r.messages = @[Message(id: "1", frm: "alice", text: "hi",
                           at: 1_700_000_000_000'i64)]
    s.rooms["#test"] = r
    s.current = "#test"
    # What `room.open` does, and what the tab bar reads to light Chats.
    s.screen = scChat

  test "the backlog and the rooms sit side by side when the list is up":
    # The toggle had a button and rendered nothing at all: `hideChatList` was
    # read for the button's own highlight and by nobody else.
    s.hideChatList = false
    let t = cht.chatScreen(s, true)
    check "chat-list-pane" in t.keys("vbox")
    check t.find("vbox").anyIt(it.props{"key"}.getStr() == "chat-list-pane" and
                               it.children.len > 0)
    check "messages" in t.keys("vbox")

  test "and the strip goes away when it is folded":
    s.hideChatList = true
    let t = cht.chatScreen(s, true)
    check t.find("vbox").anyIt(it.props{"key"}.getStr() == "chat-list-pane" and
                               it.children.len == 0)

  test "the people strip is beside the backlog, not instead of it":
    # It used to take the whole pane on a narrow window, so asking who was in
    # a room meant losing the room while you looked.
    s.windowWidth = wideWidth - 1  # one pane at a time
    s.showUsers = true
    let t = cht.chatScreen(s, true)
    check t.find("vbox").anyIt(it.props{"key"}.getStr() == "people-pane" and
                               it.children.len > 0)
    check t.find("scroll").anyIt(
      it.props{"scrollKey"}.getStr() == "messages-#test")

  test "the way to Discover and Settings is on the screen":
    # It was not: the chat screen never carried the tab bar, and on a wide
    # window there is no back button either — the room list is a strip. So
    # from a conversation there was no way to either of them at all.
    let t = cht.chatScreen(s, true)
    check "Discover" in t.labels("button")
    check "Settings" in t.labels("button")

  test "and Chats is lit, because a conversation is what it leads to":
    let t = cht.chatScreen(s, true)
    let chats = t.find("button").filterIt(
      it.props{"label"}.getStr() == "Chats")
    check chats.len == 1
    check chats[0].props{"kind"}.getStr() == "primary"

  test "but not on a narrow window, which has no room for them":
    # Three tabs go to two lines at 300 points, and this screen has no 120
    # points to spare — `← Chats` is the way back there instead.
    s.windowWidth = wideWidth - 1
    let t = cht.chatScreen(s, true)
    check "Discover" notin t.labels("button")
    check "←" in t.labels("button")

  test "a room in the strip opens it, and the current one is lit":
    s.hideChatList = false
    let t = cht.chatScreen(s, true)
    let side = t.find("button").filterIt(
      it.props{"key"}.getStr().startsWith("side-"))
    check side.len == 1
    check side[0].props{"onClick"}.getStr() == "room.open:#test"
    check side[0].props{"kind"}.getStr() == "primary"

suite "the sender's row":
  setup:
    var s = initState()
    s.formNick = "me"
    s.rooms.ensureRoom("#test")
    var r = s.rooms["#test"]
    r.messages = @[Message(id: "1", frm: "alice", text: "hi",
                           at: 1_700_000_000_000'i64)]
    s.rooms["#test"] = r
    s.current = "#test"

  test "on a wide window the chips are carried to the right edge":
    # `align: end` on the chips never did anything: the row was a Wrap, which
    # packs from the left and has no slack to align with. What moves them is
    # the name expanding — it is drawn at the left of a box that grows, so
    # everything after it ends up against the far edge.
    s.windowWidth = wideWidth
    let t = cht.chatScreen(s, true)
    let senderRows = t.find("hbox").filterIt(
      it.children.anyIt(it.tag == "avatar"))
    check senderRows.len == 1
    check not senderRows[0].props{"wrap"}.getBool()
    check senderRows[0].children.anyIt(
      it.tag == "button" and it.props{"expand"}.getBool())

  test "on a narrow one it wraps instead, and nothing is pushed off":
    # With the name shrunk to nothing the face, the time and three chips
    # still ask for more than a phone has, so there the row wraps as before —
    # and nothing expands, because a Wrap has no slack to give.
    s.windowWidth = wideWidth - 1  # one pane at a time
    let t = cht.chatScreen(s, true)
    let senderRows = t.find("hbox").filterIt(
      it.children.anyIt(it.tag == "avatar"))
    check senderRows.len == 1
    check senderRows[0].props{"wrap"}.getBool()
    check not senderRows[0].children.anyIt(
      it.tag == "button" and it.props{"expand"}.getBool())

suite "the editing banner":
  setup:
    var s = initState()
    s.formNick = "me"
    s.current = "#test"
    s.rooms.ensureRoom("#test")
    var r = s.rooms["#test"]
    r.messages = @[Message(id: "1", frm: "me", text: "regrettable", at: 1)]
    s.rooms["#test"] = r

  test "offers no delete when nothing is being edited":
    let t = cht.chatScreen(s, true)
    check "edit.delete" notin t.find("button").mapIt(
      it.props{"onClick"}.getStr())

  test "but does while a line is open for editing":
    # The moment a reader is already looking at one line and deciding what
    # to do with it is the moment to offer the other thing they might want.
    s.editing = EditTarget(has: true, room: "#test", id: "1")
    let t = cht.chatScreen(s, true)
    let b = t.find("button").filterIt(
      it.props{"onClick"}.getStr() == "edit.delete")
    check b.len == 1
    check b[0].props{"label"}.getStr() == "Delete"
    # Deleting is not undoable — freeq leaves the line out of history — so
    # it should not look like the cancel beside it.
    check b[0].props{"kind"}.getStr() == "destructive"
