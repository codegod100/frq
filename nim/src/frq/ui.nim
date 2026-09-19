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
func page*(props: JsonNode, children: varargs[Node]): Node =
  n("page", props, @children)

func label*(text: string): Node = n("label", %*{"label": text})
func dimLabel*(text: string): Node = n("dim-label", %*{"label": text})
func title*(text: string): Node = n("title", %*{"label": text})
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
