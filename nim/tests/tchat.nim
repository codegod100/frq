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

  test "every line names its sender":
    # Not the first of a run only: answering the fourth line of a collapsed
    # run quotes back a line with no name on it.
    check cs.chatScreen(s, true).labels("label").countIt(it == "alice") == 1
    check cs.chatScreen(s, true).labels("label").countIt(it == "frq-guest") == 1

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
    # 🙂 and ↩️ on both messages, ✏️ on ours alone.
    check chips.countIt(it == "✏️") == 1
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
    check "← Chats" in cs.chatScreen(s, true).labels("button")
    s.windowWidth = 1200
    let wide = cs.chatScreen(s, true)
    check "← Chats" notin wide.labels("button")
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
    check "alice" in t.labels("label")

  test "Jump to present only when we are not at it":
    check "↓ Jump to present" notin cs.chatScreen(s, true).labels("button")
    s.atPresent = false
    check "↓ Jump to present" in cs.chatScreen(s, true).labels("button")

  test "the compose bar is always there, with a send":
    let t = cs.chatScreen(s, true)
    check "draft" in t.find("entry").mapIt(it.props{"key"}.getStr())
    check "Send" in t.labels("button")
