## Slash commands: what a `/` line means, and what goes on the wire for it.

import std/[json, sequtils, strutils, tables, unittest]
import frq/[cells, commands, complete, model, reducer]
import frq/conn as tr

suite "parseCommand":
  test "a line without a slash is said":
    check parseCommand("hello", "#a").kind == ckNone
    check parseCommand("/", "#a").kind == ckNone
    check parseCommand("/ x", "#a").kind == ckNone
  test "a doubled slash is said, one slash shorter":
    check parseCommand("//shrug", "#a").kind == ckNone
    check unescapeSlash("//shrug") == "/shrug"
    check unescapeSlash("plain") == "plain"
  test "join adds the # it was not given":
    let c = parseCommand("/join freeq", "")
    check c.kind == ckJoin
    check c.target == "#freeq"
    check parseCommand("/JOIN #x key", "").text == "key"
    check parseCommand("/join", "").kind == ckUsage
  test "part leaves this room unless another is named":
    check parseCommand("/part bye now", "#a").target == "#a"
    check parseCommand("/part bye now", "#a").text == "bye now"
    check parseCommand("/part #b", "#a").target == "#b"
    check parseCommand("/part", "").kind == ckUsage
  test "msg needs someone and something":
    let c = parseCommand("/msg bob  hi there", "#a")
    check c.kind == ckMsg
    check c.target == "bob"
    check c.text == "hi there"
    check parseCommand("/msg bob", "#a").kind == ckUsage
  test "query may come with a first line":
    check parseCommand("/query bob", "").kind == ckQuery
    check parseCommand("/query bob hi", "").text == "hi"
  test "me, nick, topic, quit, help":
    check parseCommand("/me waves", "#a").text == "waves"
    check parseCommand("/me", "#a").kind == ckUsage
    check parseCommand("/nick zed", "#a").target == "zed"
    check parseCommand("/topic new words", "#a").text == "new words"
    check parseCommand("/topic", "bob").kind == ckUsage
    check parseCommand("/quit gone", "").text == "gone"
    check parseCommand("/help", "").kind == ckHelp
  test "anything else goes out as typed, its verb uppercased":
    check parseCommand("/whois alice", "").text == "WHOIS alice"
    check parseCommand("/quote MODE #a +o bob", "").text == "MODE #a +o bob"
    check parseCommand("/raw", "").kind == ckUsage

suite "ACTION":
  test "round trip":
    check actionLine("waves") == "\x01ACTION waves\x01"
    check ctcpAction("\x01ACTION waves\x01") == ("waves", true)
    check ctcpAction("\x01ACTION waves") == ("waves", true)
    check ctcpAction("waves") == ("waves", false)

suite "Tab completes commands":
  let cmds = commandNames()
  test "at the start of the line":
    let t = tabComplete("/jo", 3, @["joe"], @[], TabState(), commands = cmds)
    check t.text == "/join "
  test "not mid-line, where a slash is just a slash":
    check not tabComplete("hi /jo", 6, @[], @[], TabState(),
                          commands = cmds).active
  test "several cycle like nicks do":
    let a = tabComplete("/q", 2, @[], @[], TabState(), commands = cmds)
    check a.matches == @["/query", "/quit", "/quote"]
    check a.text == "/qu"

proc sent(): seq[string] =
  while true:
    let (ok, line) = tr.tryOutbound()
    if not ok: break
    result.add line

proc typed(line: string) =
  dispatch(%*{"id": "draft.change", "value": line})
  dispatch(%*{"id": "send"})

proc reset() =
  app = initState()
  forgetPending()
  app.formNick = "alice"
  tr.feed(":alice!a@h JOIN #freeq")
  drain()
  dispatch(%*{"id": "room.open:#freeq"})
  discard sent()

suite "commands on the wire":
  setup: reset()

  test "join sends JOIN and opens the room":
    typed("/join test")
    check "JOIN #test" in sent()
    check app.current == "#test"
    check app.draft == ""
  test "part sends PART with a reason and closes the room":
    typed("/part see you")
    check "PART #freeq :see you" in sent()
    check not app.rooms.hasKey("#freeq")
  test "me sends an ACTION and shows it as one":
    typed("/me waves")
    check "PRIVMSG #freeq :\x01ACTION waves\x01" in sent()
    let m = app.rooms["#freeq"].messages[^1]
    check m.action
    check m.text == "waves"
  test "an incoming ACTION is shown as one":
    tr.feed(":bob!b@h PRIVMSG #freeq :\x01ACTION nods\x01")
    drain()
    let m = app.rooms["#freeq"].messages[^1]
    check m.action and m.text == "nods"
  test "msg goes to the nick and stays here":
    typed("/msg bob psst")
    check "PRIVMSG bob :psst" in sent()
    check app.current == "#freeq"
    check app.rooms["bob"].messages[^1].text == "psst"
  test "query opens the conversation":
    typed("/query bob")
    check app.current == "bob"
  test "nick and topic":
    typed("/nick zed")
    typed("/topic hello all")
    let wire = sent()
    check "NICK zed" in wire
    check "TOPIC #freeq :hello all" in wire
  test "an unknown command is sent raw":
    typed("/whois bob")
    check "WHOIS bob" in sent()
  test "help is said to the reader, and only to them":
    typed("/help")
    check sent().len == 0
    check app.rooms["#freeq"].messages.anyIt(it.text.startsWith("/join"))
  test "a usage mistake keeps the draft and says why":
    typed("/msg bob")
    check sent().len == 0
    check app.hasError
    check "Usage: /msg" in app.error
    check app.draft == "/msg bob"
  test "a doubled slash is said":
    typed("//shrug")
    check "PRIVMSG #freeq :/shrug" in sent()
  test "an incoming TOPIC changes the room's":
    tr.feed(":bob!b@h TOPIC #freeq :new topic")
    drain()
    check app.rooms["#freeq"].topic == "new topic"
