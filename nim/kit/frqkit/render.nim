## The renderer: the core's widget tree, walked into nimkit widgets.
##
## This knows the tag vocabulary and nothing else — no screens, no state, no
## idea what "connect" means. Nim decides what the screen is; this decides
## what a `vbox` is made of. It is the same job `flutter/lib/nim_renderer.dart`
## did, in the same process as the core now: the tree is read as `ui.Node`s
## rather than crossing a boundary as JSON.
##
## The core rebuilds the whole tree whenever the state moves, and nimkit's
## widgets are retained, so the work here is reconciling: a node that is the
## same as last time keeps its widget, and one that changed is patched or
## rebuilt. That is not an optimisation. A text field rebuilt on every
## keystroke loses its caret, a scroll rebuilt on every line loses its place,
## and a label rebuilt under the pointer loses the selection being dragged.
##
## Children are matched by `key` where the tree gives one and by position
## where it does not — the same rule Flutter's elements followed, and the
## reason the screens put a key on everything that comes and goes.
##
## Colours are not here. Every widget is given style classes (`card`, `dim`,
## `pill`…), and `theme.nim` says what those look like on each platform.

import std/[json, strutils, tables, unicode]
import nimkit
from frq/ui import Node

var
  sendHook*: proc (id, value: string)
    ## An event, for the core to apply — a press, a toggle, Enter. The screen
    ## it produces is painted on the next `render`.
  inputHook*: proc (id, value: string)
    ## A keystroke in a field that carries a revision: applied, and nothing
    ## painted for it. See `ui.entry`.
  clipboardHasPicture*: proc (): bool
    ## Whether a paste is about to be a picture rather than text. Only the
    ## desktop can ask; a browser says so through the page's `paste` event.
  insertImage*: string
    ## The compose bar's picture button, as PNG bytes — `asset:` sources in
    ## the tree name the Flutter bundle's assets, and this is the only one.

type
  Mount = ref object
    ## One node of the tree as it is on screen.
    tag, key: string
    props: JsonNode        ## what the widget was last made from
    outer: Widget          ## what sits in the parent
    box: Widget            ## where the children go; nil for a leaf
    kids: seq[Mount]
    field: Widget          ## an entry's own field (`outer` may be a frame)
    rev: int               ## the revision an entry last took its text at
    tick: int              ## the `scrollToBottom` a scroll last acted on
    jumped: bool           ## `scrollHere` already acted on
    maxWidth: int          ## a page's widest

var
  root*: Widget            ## the window's content
  windowWidth*: int        ## as the host last measured it
  pages: seq[Mount]
  top: Mount
  fields: Table[string, Widget]   ## entries by key, for giving one the focus back
  queued: seq[(string, string)]

proc focusField*(key: string)

proc send(id: string, value = "") =
  ## Every event goes through here, and none is applied while a widget is
  ## being built: an event raised by building (a jump arriving) waits for the
  ## walk to finish.
  if id.len == 0: return
  queued.add (id, value)
  discard after(0, proc () =
    while queued.len > 0:
      let (i, v) = queued[0]
      queued.delete 0
      if sendHook != nil: sendHook(i, v)
      # Send leaves the reader where they were: in the message box.
      if i == "send": focusField("draft"))

proc str(p: JsonNode, k: string, d = ""): string =
  if p.isNil or p.kind != JObject: return d
  let v = p{k}
  if v.isNil or v.kind != JString: d else: v.getStr
proc num(p: JsonNode, k: string, d = 0): int =
  if p.isNil or p.kind != JObject: return d
  let v = p{k}
  if v.isNil: d
  elif v.kind == JInt: v.getInt
  elif v.kind == JFloat: int(v.getFloat)
  else: d
proc flag(p: JsonNode, k: string, d = false): bool =
  if p.isNil or p.kind != JObject: return d
  let v = p{k}
  if v.isNil or v.kind != JBool: d else: v.getBool

proc cls(w: Widget, names: varargs[string]): Widget {.discardable.} =
  for n in names:
    if n.len > 0: w.addClass(n)
  w

# --------------------------------------------------------------- text spans

proc utf16ToRunes(s: string, units: int): int =
  ## The caret the core speaks (UTF-16 code units, which is Dart's and the
  ## browser's) as the one nimkit speaks (characters).
  var u = 0
  for r in s.runes:
    if u >= units: break
    u += (if r.int > 0xFFFF: 2 else: 1)
    inc result

proc runesToUtf16(s: string, n: int): int =
  var i = 0
  for r in s.runes:
    if i >= n: break
    result += (if r.int > 0xFFFF: 2 else: 1)
    inc i

proc spanMarkup(n: Node): string =
  ## One inline node of a paragraph, as the little markup a rich label takes.
  let p = n.props
  case n.tag
  of "link":
    let click = p.str("onClick")
    let url = if click.len > 0: "frq-event:" & click else: p.str("url", p.str("label"))
    "<a href=\"" & escapeRich(url) & "\">" & escapeRich(p.str("label")) & "</a>"
  of "strong": "<b>" & escapeRich(p.str("text")) & "</b>"
  of "emphasis": "<i>" & escapeRich(p.str("text")) & "</i>"
  of "code": "<tt>" & escapeRich(p.str("text")) & "</tt>"
  else: escapeRich(p.str("text", p.str("label")))

proc prose(markup: string): Widget =
  ## Wrapping, selectable text with links in it. A link that names an event
  ## sends it; any other opens where the platform opens links.
  result = richLabel(markup, selectable = true)
  result.onLink = proc (url: string): bool =
    if url.startsWith("frq-event:"):
      send(url[10 .. ^1])
      return true
    false

# ------------------------------------------------------------------- build

proc build(n: Node, axis: char): Mount
proc patchKids(m: Mount, kids: seq[Node], axis: char)

proc childAxis(n: Node): char =
  ## What a node's children are laid out along: 'c'olumn, 'r'ow, or neither.
  case n.tag
  of "page", "vbox", "card", "task-card", "scroll", "dialog", "overlay": 'c'
  of "hbox": 'r'
  else: ' '

proc fitPage(w: Widget, most: int) =
  let room = if windowWidth > 0: windowWidth - 2 else: most
  discard w.sized(max(min(most, room), 200), 0)

proc spaced(w: Widget, p: JsonNode, d = 0): Widget =
  w.spacing = p.num("spacing", d)
  w

proc framed(inner: Widget, p: JsonNode): Widget =
  ## `margin` and its four sides — the props the screens use to buy air
  ## without a wrapper each time. Uniform air is the box's own padding; air
  ## on some sides only is a frame of fixed gaps around it.
  let all = p.num("margin")
  let t = p.num("marginTop", all)
  let b = p.num("marginBottom", all)
  let l = p.num("marginLeft", all)
  let r = p.num("marginRight", all)
  if t == 0 and b == 0 and l == 0 and r == 0: return inner
  if t == b and b == l and l == r and inner.kind in {wkColumn, wkRow}:
    inner.padding = t
    return inner
  proc gap(w, h: int): Widget =
    result = column()
    result.spacing = 0
    discard result.sized(w, h)
  var across = row()
  across.spacing = 0
  if l > 0: across.add gap(l, 0)
  across.add inner
  inner.expanded = true
  if r > 0: across.add gap(r, 0)
  result = column()
  result.spacing = 0
  if t > 0: result.add gap(0, t)
  result.add across
  across.expanded = true
  if b > 0: result.add gap(0, b)

proc hugging(w: Widget, axis: char): Widget =
  ## A control in a column, kept to its own width. A column stretches its
  ## children across, which is right for text and wrong for a button: a
  ## "Mark all read" as wide as the side panel is a bar, not a button.
  if axis != 'c': return w
  result = row(w)
  result.spacing = 0

proc centred(w: Widget, axis: char): Widget =
  ## A small thing in a row, kept to its own height and centred against
  ## what is taller beside it: a face is round, and a row stretches.
  if axis != 'r': return w
  result = column(spacer(), w, spacer())
  result.spacing = 0

proc button(m: Mount, p: JsonNode, axis: char): Widget =
  let click = p.str("onClick")
  let text = p.str("label")
  case p.str("kind", "default")
  of "plain":
    # A sender's name, a room in the list: text that takes a press, with no
    # chrome. Ellipsised, and taking the slack where it expands, so the time
    # and the chips after it are carried to the far edge.
    let l = label(text)
    l.maxChars = 48
    result = item(l, onClick = proc () = send(click)).cls("plain")
    if p.flag("expand") and axis == 'r': result.expanded = true
    else: result = result.hugging(axis)
  of "compact", "compact-on":
    result = button(text, proc () = send(click)).cls("compact")
    if p.str("kind") == "compact-on": result.cls("on")
    result = result.hugging(axis)
  else:
    result = button(text, proc () = send(click))
    case p.str("kind")
    of "primary": result.cls("suggested")
    of "destructive": result.cls("destructive")
    else: discard
    if p.flag("expand") and axis == 'r': result.expanded = true
    else: result = result.hugging(axis)

proc entryField(m: Mount, p: JsonNode, axis: char): Widget =
  let key = p.str("key")
  let f = entry(p.str("placeholder"), p.str("text"))
  m.field = f
  m.rev = p.num("rev", -1)
  f.onChange = proc (text: string) =
    let id = m.props.str("onChange")
    if m.props.num("rev", -1) >= 0:
      if inputHook != nil and id.len > 0: inputHook(id, text)
    else: send(id, text)
  f.onSubmit = proc (text: string) =
    let id = m.props.str("onSubmit")
    send(id)
    if id == "send": f.focus()
  f.onEntryKey = proc (e: KeyEvent): bool =
    # Tab completes rather than moving the focus on, where the field says
    # so; Shift-Tab goes back. Ctrl-Tab and Alt-Tab are the window's.
    if e.code == 0x09 and (e.mods and (modCtrl or modAlt or modSuper)) == 0:
      let id = m.props.str("onTab")
      if id.len == 0: return false
      let caret = runesToUtf16(f.text, f.caret)
      send(if (e.mods and modShift) != 0: id & ":back" else: id, $caret)
      return true
    # A paste is watched, not taken over: the key goes on to paste whatever
    # text there is, and the clipboard is asked beside it whether it holds a
    # picture instead.
    let paste = (e.code == 0x56 and (e.mods and modCtrl) != 0) or
                (e.code == 0x2D and (e.mods and modShift) != 0)
    if paste:
      let id = m.props.str("onPastePicture")
      if id.len > 0 and clipboardHasPicture != nil and clipboardHasPicture():
        send(id)
    false
  if key.len > 0: fields[key] = f
  let w = p.num("widthRequest")
  if w > 0: discard f.sized(w, 0)
  elif axis == 'r': f.expanded = true
  else: discard f.sized(320, 0)
  f.cls("field")

proc syncEntry(m: Mount, p: JsonNode) =
  ## A field takes its text from the tree only when the core rewrote it: a
  ## field with a revision hands its keystrokes over with no tree back, so the
  ## tree in hand can be older than what is in the box.
  let f = m.field
  f.placeholder = p.str("placeholder")
  let rev = p.num("rev", -1)
  let rewritten = rev < 0 or rev != m.rev
  m.rev = rev
  let text = p.str("text")
  if rewritten and f.text != text:
    f.text = text
    let caret = p.num("caret", -1)
    f.caret = if caret < 0: text.runeLen else: utf16ToRunes(text, caret)

proc avatarWidget(p: JsonNode): Widget =
  ## A face, or the letter to draw where there is none.
  let size = p.num("size", 32)
  let url = p.str("url")
  let click = p.str("onClick")
  let tap = if click.len > 0: (proc () = send(click)) else: nil
  if url.len > 0:
    result = picture(url, onClick = tap)
    discard result.sized(size, size)
    result.round = true
    result.cls("face")
  else:
    let fb = p.str("fallback")
    let letter = if fb.len > 0: fb.runeAt(0).toUpper.toUTF8 else: "?"
    result = button(letter, tap).cls("face", "letter")
    discard result.sized(size, size)

proc taskCard(m: Mount, n: Node): Widget =
  ## A typed handoff event's visible companion: a header naming its state,
  ## and the facts under it.
  let p = n.props
  let tone = p.str("tone", "neutral")
  var head = row(label(p.str("glyph")).cls("emoji"),
                 label(p.str("headline").toUpperAscii).cls("headline", "tone-" & tone))
  head.spacing = 8
  if p.str("eventId").len > 0:
    let id = label(p.str("eventId")).cls("dim", "tiny")
    id.maxChars = 14
    head.add id
  head.add spacer()
  let reply = p.str("replyOnClick")
  if reply.len > 0:
    head.add button("💬", proc () = send(reply)).cls("pill")
  head.add label(p.str("time")).cls("dim", "tiny")
  head.cls("task-head")
  m.box = column()
  m.box.spacing = 8
  m.box.cls("task-body")
  result = column(head, m.box).cls("task-card", "tone-" & tone)
  result.spacing = 0
  if p.flag("highlight"): result.cls("highlight")

proc leaf(m: Mount, n: Node, axis: char): Widget =
  let p = n.props
  case n.tag
  of "title":
    result = label(p.str("label")).cls("title")
    if p.flag("shrink"):
      result.maxChars = 40
      if axis == 'r': result.expanded = true
  of "title-2": result = label(p.str("label")).cls("title2")
  of "label": result = label(p.str("label"))
  of "dim-label": result = label(p.str("label")).cls("dim", "caption")
  of "text":
    result = prose(escapeRich(p.str("text")))
    if p.num("lines") > 0: result.maxChars = 80 * p.num("lines")
  of "code-block": result = label(p.str("text")).cls("mono", "code")
  of "paragraph":
    var markup = ""
    for c in n.children: markup.add spanMarkup(c)
    result = prose(markup)
  of "link": result = prose(spanMarkup(n))
  of "separator":
    result = separator()
    if axis == 'r':
      # A rule across, beside the words it heads (a day's), rather than the
      # upright one a row would otherwise make of it.
      let line = separator()
      result = column(line)
      result.spacing = 0
      result.padding = 9
      result.expanded = true
  of "spacer":
    let s = p.num("size", 8)
    result = column()
    result.spacing = 0
    discard result.sized(s, s)
  of "spinner":
    result = row(label("…").cls("dim"))
    if p.str("label").len > 0: result.add label(p.str("label")).cls("dim", "caption")
    result.spacing = 8
  of "status":
    result = row(label("●").cls("dot", if p.flag("live"): "live" else: "off"),
                 label(p.str("label")).cls("dim", "caption"))
    result.spacing = 6
    result = result.hugging(axis)
  of "button": result = m.button(p, axis)
  of "checkbutton":
    let click = p.str("onToggled")
    result = check(p.str("label"), p.flag("active"), proc (on: bool) = send(click))
  of "emoji":
    let glyph = p.str("glyph", p.str("emoji"))
    let click = p.str("onClick")
    result = if click.len > 0: button(glyph, proc () = send(click)).cls("emoji-button")
             else: label(glyph).cls("emoji")
    result = result.hugging(axis)
  of "reaction":
    # A pill: the glyph, and the tally beside it where there is one. The
    # same shape for a reaction, a swatch in the picker and a chip on the
    # sender's row, which is the point — what you press to react and what
    # appears once you have should look like one family.
    let count = p.num("count")
    let click = p.str("onClick")
    let text = p.str("emoji") & (if count > 0: " " & $count else: "")
    result = button(text, proc () = send(click)).cls("pill")
    if p.flag("mine"): result.cls("mine")
    result = result.hugging(axis).centred(axis)
  of "avatar": result = avatarWidget(p).hugging(axis).centred(axis)
  of "image":
    let src = p.str("src")
    let click = p.str("onClick")
    let tap = if click.len > 0: (proc () = send(click)) else: nil
    result = picture("", p.num("maxWidth"), p.num("maxHeight"), tap)
    if src.startsWith("asset:"): result.image = insertImage
    else: result.src = src
    if p.flag("expand"):
      result.expanded = true
    else: result = result.hugging(axis)
  of "entry": result = m.entryField(p, axis)
  else:
    # An unknown tag paints as itself rather than crashing or vanishing.
    result = label("?" & n.tag).cls("error")

proc container(m: Mount, n: Node, axis: char): Widget =
  ## The shell of a node with children; `m.box` is where they go.
  let p = n.props
  case n.tag
  of "vbox":
    m.box = column().spaced(p)
    if p.flag("background"): m.box.cls("ground")
    let w = p.num("widthRequest")
    if w > 0: discard m.box.sized(w, 0)
    result = framed(m.box, p)
    if p.flag("expand"): result.expanded = true
  of "hbox":
    # Wrapping unless the row says otherwise: `hbox` means "these go
    # together across", not "these fit". A row that cannot wrap asks for
    # the width of everything in it, and on the desktop that is a window
    # that grows past the screen.
    #
    # Only a row standing in a column wraps, and only one with nothing in it
    # that stretches: a row inside a row is given the least width it can
    # live with, which for a wrapping one is a column of its children, and
    # a stretching child has nothing to stretch into once it is on a line
    # of its own.
    var wraps = p.flag("wrap", true) and axis != 'r'
    for c in n.children:
      if not c.isNil and (c.tag in ["separator", "entry"] or c.props.flag("expand")):
        wraps = false
    m.box = (if wraps: row().wrapping else: row()).spaced(p)
    result = framed(m.box, p)
    if p.flag("expand"): result.expanded = true
  of "page":
    # Kept to a readable width and centred, where the window is wider than
    # that: a form across a whole desktop is a form nobody can scan.
    m.box = column().spaced(p).cls("page")
    m.box.padding = 24
    m.maxWidth = p.num("maxWidth", 520)
    m.box.fitPage(m.maxWidth)
    let across = row(spacer(), m.box, spacer())
    across.spacing = 0
    pages.add m
    result = scroll(across)
    result.expanded = true
  of "card":
    m.box = column().spaced(p, 8)
    let click = p.str("onClick")
    if click.len > 0:
      # The whole card is the control, where every line in a list goes
      # somewhere: a large target rather than a button beside a large inert
      # thing.
      m.box.expanded = true
      result = item(m.box, onClick = proc () = send(click)).cls("card", "card-button")
    else:
      result = m.box.cls("card")
    if p.flag("task"): result.cls("task")
  of "task-card": result = m.taskCard(n)
  of "dialog":
    m.box = column().spaced(p)
    let t = p.str("title")
    result = if t.len > 0: column(label(t).cls("title2"), m.box) else: column(m.box)
    result.cls("dialog")
  of "scroll":
    m.box = column().spaced(p)
    m.box.cls("scrolled")
    result = scroll(m.box)
    result.expanded = true
    m.tick = p.num("scrollToBottom")
    if p.flag("stickToBottom"):
      # The backlog reads from the bottom, and says whether the reader is
      # at the present — which is what puts "Jump to present" up.
      result.followEnd = true
      result.onFollow = proc (following: bool) =
        send(if following: "present.back" else: "present.left")
    elif p.flag("fromBottom"):
      result.followEnd = true
  of "overlay":
    # Things that float over the backlog sit under it here: nimkit has no
    # stack. The one that covers it — a picture being looked at — takes the
    # backlog's place while it is up.
    m.box = column()
    m.box.spacing = 4
    result = m.box
    if p.flag("expand"): result.expanded = true
  else: discard

proc isContainer(tag: string): bool =
  tag in ["vbox", "hbox", "page", "card", "task-card", "dialog", "scroll", "overlay"]

proc settle(m: Mount, n: Node) =
  ## What a node asks for once its children are in.
  if n.tag == "overlay" and m.kids.len > 0:
    var covering = false
    for k in m.kids[1 .. ^1]:
      if k.props.flag("fill") and k.kids.len > 0:
        covering = true
        k.outer.expanded = true
      elif k.props.flag("fill"):
        k.outer.expanded = false
    m.kids[0].outer.visible = not covering
  if n.props.flag("scrollHere") and not m.jumped:
    m.jumped = true
    m.outer.reveal()
    send("jump.done")
  elif not n.props.flag("scrollHere"):
    m.jumped = false

proc build(n: Node, axis: char): Mount =
  result = Mount(tag: n.tag, key: n.props.str("key"), props: n.props, rev: -1)
  if n.tag.isContainer:
    result.outer = result.container(n, axis)
    result.patchKids(n.children, n.childAxis)
    if n.tag == "overlay" and result.kids.len > 0:
      # The base takes the room; what floats over it does not.
      result.kids[0].outer.expanded = true
  else:
    result.outer = result.leaf(n, axis)
  result.settle(n)

proc patch(m: Mount, n: Node, axis: char): Mount =
  ## `m` brought up to `n`: the same mount where it could be kept, a new one
  ## where it could not.
  if m.tag != n.tag or m.key != n.props.str("key"): return build(n, axis)
  case n.tag
  of "entry":
    # Kept whatever changed, so the caret and the focus stay where they are.
    if m.props.num("widthRequest") != n.props.num("widthRequest"): return build(n, axis)
    m.props = n.props
    m.syncEntry(n.props)
    return m
  of "scroll":
    if m.props.str("scrollKey") != n.props.str("scrollKey") or
        m.props.flag("stickToBottom") != n.props.flag("stickToBottom"):
      return build(n, axis)
    let tick = n.props.num("scrollToBottom")
    if tick != m.tick:
      # "Jump to present": a tick that goes up rather than a flag that would
      # have to be cleared.
      m.tick = tick
      m.outer.followEnd = true
    m.props = n.props
    m.patchKids(n.children, n.childAxis)
    m.settle(n)
    return m
  else: discard
  if n.tag.isContainer:
    if m.props != n.props:
      # A new shell around the children it already had: they are moved, not
      # rebuilt, so what is inside a card that lit up keeps its state.
      let fresh = Mount(tag: n.tag, key: m.key, props: n.props, rev: -1, jumped: m.jumped)
      fresh.outer = fresh.container(n, axis)
      for k in m.kids:
        if k.outer.parent != nil: k.outer.parent.remove(k.outer, keep = true)
      fresh.kids = m.kids
      fresh.patchKids(n.children, n.childAxis)
      if n.tag == "overlay" and fresh.kids.len > 0: fresh.kids[0].outer.expanded = true
      fresh.settle(n)
      return fresh
    m.patchKids(n.children, n.childAxis)
    m.settle(n)
    return m
  if m.props != n.props: return build(n, axis)
  if n.tag == "paragraph":
    # A paragraph's words are its children rather than its props, and a
    # label whose text changed is the same label: set, not rebuilt, so a
    # selection elsewhere in the backlog survives a line being edited.
    var markup = ""
    for c in n.children: markup.add spanMarkup(c)
    m.outer.text = markup
  m.settle(n)
  m

proc patchKids(m: Mount, kids: seq[Node], axis: char) =
  var byKey: Table[string, int]
  for i, k in m.kids:
    if k.key.len > 0: byKey[k.key] = i
  var used = newSeq[bool](m.kids.len)
  var next: seq[Mount]
  for i, c in kids:
    if c.isNil: continue
    let key = c.props.str("key")
    var j = -1
    if key.len > 0:
      j = byKey.getOrDefault(key, -1)
    elif next.len < m.kids.len and m.kids[next.len].key.len == 0:
      j = next.len
    if j >= 0 and not used[j]:
      used[j] = true
      let old = m.kids[j]
      let fresh = old.patch(c, axis)
      if fresh.outer != old.outer and old.outer.parent != nil:
        old.outer.parent.remove(old.outer)
      next.add fresh
    else:
      next.add build(c, axis)
  for j, k in m.kids:
    if not used[j] and k.outer.parent == m.box:
      m.box.remove(k.outer)
  for i, k in next:
    if i >= m.box.children.len or m.box.children[i] != k.outer:
      m.box.insert(k.outer, i)
  m.kids = next

# ------------------------------------------------------------------- render

proc render*(tree: Node) =
  ## Bring the window up to `tree`.
  if tree.isNil: return
  var kept: seq[Mount]
  for m in pages:
    if m.box.realized or m.box.parent != nil:
      m.box.fitPage(m.maxWidth)
      kept.add m
  pages = kept
  if top.isNil:
    top = build(tree, 'c')
    root.add top.outer
  else:
    let fresh = top.patch(tree, 'c')
    if fresh.outer != top.outer:
      root.remove(top.outer)
      root.add fresh.outer
    top = fresh
  top.outer.expanded = true

proc focusField*(key: string) =
  let f = fields.getOrDefault(key)
  if f != nil and f.realized: f.focus()

proc newRoot*(): Widget =
  root = column()
  root.spacing = 0
  root.cls("frq")
  root
