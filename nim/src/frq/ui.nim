## The widget tree Nim hands Dart, and the little DSL for building one.
##
## The shape is the hiccup the ClojureDart screens already produce — a tag, a
## props table, children — because the vocabulary is the part worth keeping.
## `frq.hiccup` interprets exactly these tags into Flutter widgets today, so a
## tree emitted here and a tree emitted there describe the same screen, and
## the renderer on the Dart side is the same idea rewritten rather than a new
## one invented.
##
## The one real difference is callbacks. In Clojure a prop holds a closure;
## across a C ABI it cannot, so `onClick` holds an **event id** instead — an
## opaque string Dart sends back to `dispatch`. That is what turns this from a
## rendering trick into an architecture: Nim owns the state, Dart owns the
## pixels, and the only things crossing are a tree going out and an event id
## coming back.

import std/json

type
  Node* = ref object
    ## A widget. `props` is deliberately untyped-ish — a JsonNode — because
    ## the tags disagree about what they take and a variant per tag would be
    ## a second place to edit every time one gains a property.
    tag*: string
    props*: JsonNode
    children*: seq[Node]

func n*(tag: string, props: JsonNode = nil, children: seq[Node] = @[]): Node =
  ## The constructor everything uses. `n"vbox"` reads closely enough to
  ## `[:vbox ...]` that a screen transcribed from the Clojure stays legible
  ## beside it.
  Node(tag: tag, props: if props.isNil: newJObject() else: props, children: children)

func toJson*(node: Node): JsonNode =
  if node.isNil: return newJNull()
  result = newJObject()
  result["tag"] = %node.tag
  result["props"] = node.props
  if node.children.len > 0:
    var kids = newJArray()
    for c in node.children:
      if not c.isNil:
        kids.add c.toJson
    result["children"] = kids

# --------------------------------------------------------------- shorthands
#
# Props are written as `%*{...}` at the call sites, which is Nim's JSON
# literal. It is noisier than Clojure's map but it is checked: a typo in a key
# is still a typo, but a typo in the *shape* — a string where a number goes —
# fails at the boundary rather than three layers into Flutter.

func vbox*(props: JsonNode, children: varargs[Node]): Node =
  n("vbox", props, @children)
func hbox*(props: JsonNode, children: varargs[Node]): Node =
  n("hbox", props, @children)
func card*(children: varargs[Node]): Node =
  n("card", newJObject(), @children)
func card*(props: JsonNode, children: varargs[Node]): Node =
  ## A card with props — `onClick` makes the whole card the control, for a
  ## list whose every line goes somewhere.
  n("card", props, @children)
func page*(props: JsonNode, children: varargs[Node]): Node =
  n("page", props, @children)

func label*(text: string): Node = n("label", %*{"label": text})
func dimLabel*(text: string): Node = n("dim-label", %*{"label": text})
func title*(text: string, shrink = false): Node =
  ## `shrink` is a title that yields: it takes what a row has left over and
  ## ellipsises rather than pushing what follows it off the end. Distinct
  ## from `expand`, which claims the slack instead of giving it up.
  var p = %*{"label": text}
  if shrink: p["shrink"] = %true
  n("title", p)
func title2*(text: string): Node = n("title-2", %*{"label": text})
func spinner*(): Node = n("spinner")

func button*(text: string, onClick: string, kind = "default"): Node =
  ## `onClick` is an event id, not a closure. See the module comment.
  n("button", %*{"label": text, "kind": kind, "onClick": onClick})

func entry*(key, text, placeholder, onChange: string, width = 0,
            onSubmit = ""): Node =
  ## Every entry carries a key, and for the reason the Clojure's comment
  ## gives: a renderer that keeps a text controller per field needs a stable
  ## name for it, and without one the host and the port shared a controller
  ## and both showed the port.
  var p = %*{"key": key, "text": text, "placeholder": placeholder,
             "onChange": onChange}
  if width > 0: p["widthRequest"] = %width
  # Enter, where the field has something to do with it. A compose box that
  # only sends on a button click is one nobody can type into at speed.
  if onSubmit.len > 0: p["onSubmit"] = %onSubmit
  n("entry", p)

func checkbutton*(text: string, active: bool, onToggled: string): Node =
  n("checkbutton", %*{"label": text, "active": active, "onToggled": onToggled})

func scroll*(props: JsonNode, children: varargs[Node]): Node =
  ## A list that is taller than the room it has. The renderer decides how that
  ## is done; the tree only says that it is expected.
  n("scroll", props, @children)

# ------------------------------------------------- the rest of the vocabulary
#
# Every tag the real screens use. `frq.hiccup` interprets exactly these into
# Flutter widgets today, so a tree emitted here describes the same screen it
# describes there — which is what makes the port a transcription rather than a
# redesign.

func separator*(): Node = n("separator")

func spacer*(size: int): Node = n("spacer", %*{"size": size})

func paragraph*(children: varargs[Node]): Node =
  ## Prose with links in it, wrapping as text rather than as boxes.
  ##
  ## Its own tag rather than an `hbox` with an `inline` flag, which is what it
  ## was: a row and a paragraph share no layout at all — not the gaps, not the
  ## alignment, not even how a child is built — so saying "row" and then
  ## contradicting it with a prop meant the renderer had to check the
  ## contradiction before every row it drew.
  n("paragraph", newJObject(), @children)

func text*(body: string, lines = 0): Node =
  ## Prose, as opposed to a `label`: wraps, and is the thing a message is.
  ##
  ## `lines` caps how many it may take, ellipsising after. Left at 0 it says
  ## all of itself, which is what a message in a conversation does.
  var p = %*{"text": body}
  if lines > 0: p["lines"] = %lines
  n("text", p)

func link*(label, url: string): Node =
  n("link", %*{"label": label, "url": url})

func image*(src: string, maxWidth = 0, maxHeight = 0, onClick = ""): Node =
  var p = %*{"src": src}
  if maxWidth > 0: p["maxWidth"] = %maxWidth
  if maxHeight > 0: p["maxHeight"] = %maxHeight
  if onClick.len > 0: p["onClick"] = %onClick
  n("image", p)

func overlay*(props: JsonNode, base: Node, over: varargs[Node]): Node =
  ## One node with others floating over it, bottom-centred.
  ##
  ## For the controls that belong *to* the backlog rather than beside it.
  ## "Jump to present" as a row of its own is a row the conversation does not
  ## get, and on a short window it is the row that makes the screen overflow
  ## — the chrome around the backlog already asks for more height than a 300
  ## by 500 window has.
  result = n("overlay", props, @[base])
  for o in over:
    if not o.isNil: result.children.add o

func avatar*(url, fallback: string, size = 24, onClick = ""): Node =
  ## A profile picture, or the letter to draw where there is none. The
  ## fallback is here rather than in the renderer because which letter is a
  ## question about the nick, and the nick is the tree's business.
  var p = %*{"url": url, "fallback": fallback, "size": size}
  if onClick.len > 0: p["onClick"] = %onClick
  n("avatar", p)

func reaction*(emoji: string, count: int, mine: bool, onClick: string): Node =
  ## A pill under a message. `mine` is what makes it look pressed, and is why
  ## this is not just a button with a count in it.
  n("reaction", %*{"emoji": emoji, "count": count, "mine": mine,
                   "onClick": onClick})

func status*(label: string, live = false): Node =
  ## A connection indicator. `live` is what makes the dot beside it green, and
  ## is why this is not a plain label.
  n("status", %*{"label": label, "live": live})

func emoji*(glyph, onClick: string): Node =
  n("emoji", %*{"glyph": glyph, "onClick": onClick})

func dialog*(title: string, props: JsonNode, children: varargs[Node]): Node =
  ## A panel over the screen rather than a screen of its own. `frq.screens.app`
  ## floats it where there is a pointer and draws it in place where there is
  ## not; the tree says only that it is a dialog.
  var p = if props.isNil: newJObject() else: props
  p["title"] = %title
  n("dialog", p, @children)
