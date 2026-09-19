## The screen as a pure function of the app, and the reducer that moves it.
import std/sequtils
##
## These are the tests the Clojure screens never had and could not easily
## have: a screen there is hiccup over cells a host installs, so exercising
## one means standing up a host. Here it is a function from a record to a
## tree, and a test is a call.

import std/[json, strutils]
import std/unittest
import frq/[ui, state, irc]
import frq/screens/connect as cs

# The reducer calls `irc.start` on a Connect, and a unit test has no business
# opening a socket to irc.freeq.at — it did, before this stub, and the suite
# failed on a machine with no network for reasons that had nothing to do with
# the code. The stub records what it was asked for so the tests can assert on
# it, which is more than the real one would have told them.
var dialled: seq[ConnConfig]
irc.connector = proc(cfg: ConnConfig) {.nimcall, gcsafe.} =
  {.cast(gcsafe).}: dialled.add cfg

proc find(node: Node, tag: string): seq[Node] =
  ## Every node with this tag, depth first.
  if node.isNil: return
  if node.tag == tag: result.add node
  for c in node.children:
    result.add c.find(tag)

proc texts(node: Node, tag: string): seq[string] =
  for n in node.find(tag):
    result.add n.props{"label"}.getStr()

suite "the connect screen":
  setup:
    app = initState()

  test "renders a page with the title and the server fields":
    let t = cs.connectScreen(app)
    check t.tag == "page"
    check "frq" in t.texts("title")
    check "Server" in t.texts("label")
    check t.find("checkbutton").len == 1

  test "is pure — twice with no dispatch is the same tree":
    check $cs.connectScreen(app).toJson == $cs.connectScreen(app).toJson

  test "guest is the default mode and shows a nickname field":
    let keys = cs.connectScreen(app).find("entry").mapIt(it.props{"key"}.getStr())
    check "nick" in keys
    check "handle" notin keys

  test "the selected mode is the primary button, and only it":
    let t = cs.connectScreen(app)
    var primary: seq[string]
    for b in t.find("button"):
      if b.props{"kind"}.getStr() == "primary":
        primary.add b.props{"label"}.getStr()
    # Guest is selected; Connect is primary because it is the action.
    check "Guest" in primary
    check "Bluesky" notin primary

suite "dispatch":
  setup:
    app = initState()
    dialled = @[]

  test "switching mode changes which fields are shown":
    dispatch(%*{"id": "mode.bluesky"})
    let keys = cs.connectScreen(app).find("entry").mapIt(it.props{"key"}.getStr())
    check "handle" in keys
    check "nick" notin keys

  test "typing into the host field lands in the tree":
    dispatch(%*{"id": "host.change", "value": "localhost"})
    let host = cs.connectScreen(app).find("entry").filterIt(
      it.props{"key"}.getStr() == "host")[0]
    check host.props{"text"}.getStr() == "localhost"

  test "the TLS tick carries the port with it":
    check app.formPort == "6697"
    dispatch(%*{"id": "tls.toggle"})
    check not app.formTls
    check app.formPort == "6667"
    dispatch(%*{"id": "tls.toggle"})
    check app.formPort == "6697"

  test "connecting swaps the button for a spinner":
    check cs.connectScreen(app).find("spinner").len == 0
    dispatch(%*{"id": "connect"})
    let t = cs.connectScreen(app)
    check t.find("spinner").len == 1
    check "Connect" notin t.texts("button")

  test "an empty host is refused, and the error is dismissable":
    dispatch(%*{"id": "host.change", "value": "  "})
    dispatch(%*{"id": "connect"})
    check app.hasError
    check "Dismiss" in cs.connectScreen(app).texts("button")
    dispatch(%*{"id": "error.dismiss"})
    check not app.hasError
    check "Dismiss" notin cs.connectScreen(app).texts("button")

  test "the error note keeps its place in the tree either way":
    # The bug the stable wrapper exists for: a renderer matching children by
    # position would patch the header into a card when the error appeared.
    let before = cs.connectScreen(app).children.mapIt(it.tag)
    dispatch(%*{"id": "host.change", "value": ""})
    dispatch(%*{"id": "connect"})
    check cs.connectScreen(app).children.mapIt(it.tag) == before

  test "an unknown event is ignored rather than fatal":
    let before = $cs.connectScreen(app).toJson
    dispatch(%*{"id": "no.such.event"})
    check $cs.connectScreen(app).toJson == before

suite "connecting":
  setup:
    app = initState()
    dialled = @[]

  test "Connect dials the host and port on the form":
    dispatch(%*{"id": "host.change", "value": "irc.example.org"})
    dispatch(%*{"id": "connect"})
    check dialled.len == 1
    check dialled[0].host == "irc.example.org"
    check dialled[0].port == 6697
    check dialled[0].tls
    check dialled[0].nick == "frq-guest"

  test "unticking TLS dials the plain port":
    dispatch(%*{"id": "tls.toggle"})
    dispatch(%*{"id": "connect"})
    check dialled[0].port == 6667
    check not dialled[0].tls

  test "a blank nickname is refused before anything is dialled":
    dispatch(%*{"id": "nick.change", "value": "   "})
    dispatch(%*{"id": "connect"})
    check dialled.len == 0
    check app.hasError

  test "a nonsense port falls back to the one the tick implies":
    dispatch(%*{"id": "port.change", "value": "not-a-port"})
    dispatch(%*{"id": "connect"})
    check dialled[0].port == 6697

  test "sending before registration does not queue a line":
    dispatch(%*{"id": "draft.change", "value": "hello"})
    dispatch(%*{"id": "send"})
    # Still in the box: nothing was sent, and the text was not eaten.
    check app.draft == "hello"
    check app.messages.len == 0
