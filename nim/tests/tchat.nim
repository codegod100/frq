## The conversation screen.

import std/[json, sequtils, strutils, tables, unicode, unittest]
import frq/[ui, cells, model, textruns]
import frq/screens/chat as cs

proc find(node: Node, tag: string): seq[Node] =
  if node.isNil: return
  if node.tag == tag: result.add node
  for c in node.children: result.add c.find(tag)

proc labels(node: Node, tag: string): seq[string] =
  node.find(tag).mapIt(it.props{"label"}.getStr())

proc texts(node: Node): seq[string] =
  node.find("text").mapIt(it.props{"text"}.getStr())

proc withRoom(): State =
  result = initState()
  var r = initRoom("#test")
  r.joined = true
  r.users = {"alice": "@", "bob": ""}.toTable
  r.messages = @[
    Message(id: "1", frm: "alice", text: "hello", at: 1_700_000_000_000),
    Message(id: "2", frm: "frq-guest", text: "hi back", at: 1_700_000_060_000)]
  result.rooms["#test"] = r
  result.current = "#test"
  result.formNick = "frq-guest"

suite "summarise":
  test "collapses whitespace and cuts to fit":
    check summarise("a\n  b", 36) == "a b"
    check summarise("x".repeat(50), 10).runeLen == 10
    check summarise("x".repeat(50), 10).endsWith("…")
  test "leaves a short line alone":
    check summarise("short", 36) == "short"

suite "the chat screen":
  setup:
    var s = withRoom()

  test "shows the room name and its messages":
    let t = cs.chatScreen(s, true)
    check "#test" in t.labels("title")
    check "hello" in t.texts
    check "hi back" in t.texts

  test "is pure":
    check $cs.chatScreen(s, true).toJson == $cs.chatScreen(s, true).toJson

  test "an empty room says so rather than showing nothing":
    var e = initState()
    e.rooms["#empty"] = initRoom("#empty")
    e.current = "#empty"
    check "Nothing here yet." in cs.chatScreen(e, true).labels("dim-label")

  test "every line names its sender, and the name opens them":
    # Not the first of a run only: answering the fourth line of a collapsed
    # run quotes back a line with no name on it. The name is a button because
    # it is a way in to who someone is, the same as the face beside it.
    let names = cs.chatScreen(s, true).labels("button")
    check names.countIt(it == "alice") == 1
    check names.countIt(it == "frq-guest") == 1

  test "a day heading appears where the day changes, once":
    # `at` is milliseconds. Testing it with seconds put every message on the
    # same day in 1970 and the headings quietly stopped appearing, which is
    # how the unit mismatch in the model was found.
    let t = cs.chatScreen(s, true)
    # Both messages are the same day, so one heading for the pair.
    check t.find("separator").len >= 1
    var r = s.rooms["#test"]
    r.messages.add Message(id: "3", frm: "a", text: "next day",
                           at: 1_700_200_000_000)
    s.rooms["#test"] = r
    let t2 = cs.chatScreen(s, true)
    check t2.find("separator").len > t.find("separator").len

  test "only our own lines get a pencil":
    let chips = cs.chatScreen(s, true).find("reaction")
      .mapIt(it.props{"emoji"}.getStr())
    # React and reply on both messages, edit on ours alone. Emoji-only
    # codepoints on purpose — see `actionChips`.
    check chips.countIt(it == "📝") == 1
    check chips.countIt(it == "🙂") == 2

  test "a line with no msgid gets a spacer where the chips would be":
    var r = s.rooms["#test"]
    r.messages.add Message(frm: "x", text: "no id", at: 1_700_000_120_000)
    s.rooms["#test"] = r
    # A row of the same shape rather than a row with a hole in it.
    check cs.chatScreen(s, true).find("spacer").len >= 1

  test "reaction pills carry their count and whether they are mine":
    var r = s.rooms["#test"]
    r.messages[0].reactions = @[Reaction(emoji: "👍", nicks: @["frq-guest", "bob"])]
    s.rooms["#test"] = r
    let pills = cs.chatScreen(s, true).find("reaction")
      .filterIt(it.props{"emoji"}.getStr() == "👍")
    check pills.len == 1
    check pills[0].props{"count"}.getInt() == 2
    check pills[0].props{"mine"}.getBool()

  test "links in a message become link runs":
    var r = s.rooms["#test"]
    r.messages[0].text = "see https://example.com now"
    s.rooms["#test"] = r
    check cs.chatScreen(s, true).find("link").len == 1

  test "a picture becomes an image with a lightbox click":
    var r = s.rooms["#test"]
    r.messages[0].imageUrl = "https://x.com/a.png"
    s.rooms["#test"] = r
    let img = cs.chatScreen(s, true).find("image")
      .filterIt(it.props{"src"}.getStr() == "https://x.com/a.png")
    check img.len == 1
    check img[0].props{"onClick"}.getStr().startsWith("lightbox:")

  test "a reply quotes what it answers, and offers a way there":
    var r = s.rooms["#test"]
    r.messages[1].replyTo = "1"
    s.rooms["#test"] = r
    let t = cs.chatScreen(s, true)
    check t.labels("dim-label").anyIt("↩ alice: hello" in it)
    check "→" in t.labels("button")

  test "a reply to something we no longer hold says so":
    var r = s.rooms["#test"]
    r.messages[1].replyTo = "gone"
    s.rooms["#test"] = r
    check "↩ (an earlier message)" in cs.chatScreen(s, true).labels("dim-label")

  test "hiding join/part takes the system lines out":
    var r = s.rooms["#test"]
    r.messages.add Message(frm: "*", text: "bob joined", system: true,
                           at: 1_700_000_120_000)
    s.rooms["#test"] = r
    check "bob joined" in cs.chatScreen(s, true).texts
    s.hideJoinPart = true
    check "bob joined" notin cs.chatScreen(s, true).texts

  test "the three banners hold their place whether or not they show":
    let bare = cs.chatScreen(s, true).find("vbox").mapIt(it.props{"key"}.getStr())
    s.replyingTo = ReplyTarget(has: true, frm: "alice", text: "hello")
    s.editing = EditTarget(has: true, id: "2")
    s.attachment = Attachment(has: true, path: "/tmp/a.png", status: usUploading)
    let full = cs.chatScreen(s, true).find("vbox").mapIt(it.props{"key"}.getStr())
    for k in ["replying", "editing", "attachment"]:
      check k in bare
      check k in full

  test "the banners say what they are for":
    s.replyingTo = ReplyTarget(has: true, frm: "alice", text: "hello")
    s.attachment = Attachment(has: true, path: "/p.png", status: usUploading)
    let t = cs.chatScreen(s, true)
    check t.labels("dim-label").anyIt("↩ alice: hello" in it)
    check "Uploading…" in t.labels("dim-label")
    s.attachment.status = usReady
    check "Picture attached" in cs.chatScreen(s, true).labels("dim-label")

  test "Back to chats on a narrow window, fold on a wide one":
    check "←" in cs.chatScreen(s, true).labels("button")
    s.windowWidth = 1200
    let wide = cs.chatScreen(s, true)
    check "←" notin wide.labels("button")
    check "☰ Chats" in wide.labels("button")

  test "People is offered in a channel and not in a DM":
    check cs.chatScreen(s, true).labels("button").anyIt(it.startsWith("People"))
    var dmState = initState()
    var d = initRoom("alice")
    dmState.rooms["alice"] = d
    dmState.current = "alice"
    check not cs.chatScreen(dmState, true).labels("button")
      .anyIt(it.startsWith("People"))

  test "the people panel lists who is here, only when asked":
    check "People" notin cs.chatScreen(s, true).labels("title-2")
    s.showUsers = true
    s.windowWidth = 1200
    let t = cs.chatScreen(s, true)
    check "People" in t.labels("title-2")
    # With the mode prefix in front of the name, ops first.
    check "@alice" in t.labels("label")

  test "Jump to present only when we are not at it":
    check "↓ Jump to present" notin cs.chatScreen(s, true).labels("button")
    s.atPresent = false
    check "↓ Jump to present" in cs.chatScreen(s, true).labels("button")

  test "the compose bar is always there, with a send":
    let t = cs.chatScreen(s, true)
    check "draft" in t.find("entry").mapIt(it.props{"key"}.getStr())
    check "Send" in t.labels("button")

import frq/[reducer, glyphs, emoji]

suite "the emoji picker":
  setup:
    var s = withRoom()
    app = s

  test "is not there until a message asks for it":
    check cs.chatScreen(s, true).find("entry")
      .mapIt(it.props{"key"}.getStr()).countIt(it == "emoji-search") == 0

  test "opens under the message it is for, and nowhere else":
    s.reacting = ReactTarget(has: true, room: "#test", id: "1")
    let t = cs.chatScreen(s, true)
    check t.find("entry").anyIt(it.props{"key"}.getStr() == "emoji-search")
    # One picker, not one per message.
    check t.find("entry").countIt(it.props{"key"}.getStr() == "emoji-search") == 1

  test "opens on the popular row":
    s.reacting = ReactTarget(has: true, room: "#test", id: "1")
    let picks = cs.chatScreen(s, true).find("reaction")
      .filterIt(it.props{"onClick"}.getStr().startsWith("react.pick:"))
    check picks.len == popular.len
    check picks[0].props{"emoji"}.getStr() == popular[0]

  test "a group shows that group, capped":
    s.reacting = ReactTarget(has: true, room: "#test", id: "1")
    s.emojiGroup = "Smileys & Emotion"
    let picks = cs.chatScreen(s, true).find("reaction")
      .filterIt(it.props{"onClick"}.getStr().startsWith("react.pick:"))
    # Capped: the whole catalogue crossing the boundary per keystroke is a
    # picker nobody can type into.
    check picks.len == pickerLimit

  test "search narrows it":
    s.reacting = ReactTarget(has: true, room: "#test", id: "1")
    s.emojiSearch = "grinning"
    let picks = cs.chatScreen(s, true).find("reaction")
      .filterIt(it.props{"onClick"}.getStr().startsWith("react.pick:"))
    check picks.len > 0
    check picks.len < pickerLimit

  test "a search matching nothing says so rather than showing an empty grid":
    s.reacting = ReactTarget(has: true, room: "#test", id: "1")
    s.emojiSearch = "zzzzznotanemoji"
    check "Nothing matches that." in cs.chatScreen(s, true).labels("dim-label")

suite "the overview":
  setup:
    app = withRoom()
    app.rooms["#other"] = initRoom("#other")
    var o = app.rooms["#other"]
    o.messages = @[Message(id: "o1", frm: "zoe", text: "elsewhere",
                           at: 1_700_000_500_000)]
    app.rooms["#other"] = o

  test "is not there until asked for":
    check "Overview" notin cs.chatScreen(app, true).labels("title-2")

  test "shows lines from other rooms, naming the room":
    app.overview = true
    let t = cs.chatScreen(app, true)
    check "Overview" in t.labels("title-2")
    check "#other" in t.labels("dim-label")
    check t.find("text").anyIt("elsewhere" in it.props{"text"}.getStr())

  test "leaves out the room being read":
    app.overview = true
    # #test's own lines are on screen already, directly above.
    check not cs.chatScreen(app, true).find("text")
      .anyIt("hello" in it.props{"text"}.getStr() and
             it.props{"text"}.getStr() != "hello")

  test "each line is a card that is itself the way there":
    # It used to be a row ending in a "→" button. In a Wrap on a phone the
    # button landed on a line of its own, so every entry cost three rows and
    # the smallest thing on screen was the only part that could be pressed.
    app.overview = true
    let t = cs.chatScreen(app, true)
    check "→" notin t.labels("button")
    let cards = t.find("card").filterIt(
      it.props{"onClick"}.getStr().startsWith("overview.goto:"))
    check cards.len == 1
    check cards[0].props{"onClick"}.getStr() == "overview.goto:#other:o1"

  test "an empty one says so":
    var lonely = withRoom()
    lonely.overview = true
    check "Nothing has happened anywhere else." in
      cs.chatScreen(lonely, true).labels("dim-label")

  test "going somewhere from it offers the way back":
    app.overview = true
    dispatch(%*{"id": "overview.goto:#other:o1"})
    check app.current == "#other"
    check app.overviewReturn == "#test"
    check not app.overview
    check cs.chatScreen(app, true).labels("button").anyIt("back to #test" in it)

  test "and the way back works":
    app.overview = true
    dispatch(%*{"id": "overview.goto:#other:o1"})
    dispatch(%*{"id": "overview.back"})
    check app.current == "#test"
    check app.overviewReturn == ""

suite "the lightbox":
  setup:
    var s = withRoom()
    app = s

  test "is not there until a picture is opened":
    check "Picture" notin cs.chatScreen(s, true).labels("title-2")

  test "shows the picture and a way out":
    s.lightbox = Lightbox(has: true, url: "https://x.com/a.png",
                          path: "https://x.com/a.png")
    let t = cs.chatScreen(s, true)
    check "Picture" in t.labels("title-2")
    check "Close" in t.labels("button")
    check t.find("image").anyIt(it.props{"src"}.getStr() == "https://x.com/a.png")

  test "clicking a picture opens it":
    var r = app.rooms["#test"]
    r.messages[0].imageUrl = "https://x.com/a.png"
    app.rooms["#test"] = r
    let img = cs.chatScreen(app, true).find("image")
      .filterIt(it.props{"src"}.getStr() == "https://x.com/a.png")
    check img.len == 1
    dispatch(%*{"id": img[0].props{"onClick"}.getStr()})
    check app.lightbox.has
    check app.lightbox.url == "https://x.com/a.png"

  test "and closing it puts it away":
    dispatch(%*{"id": "lightbox:https://x.com/a.png"})
    dispatch(%*{"id": "lightbox.close"})
    check not app.lightbox.has
