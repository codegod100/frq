## Message text split into words and pictures.
##
## From `common/frq/glyphs.cljc`. What it is for: a node draws one picture, so
## the renderer needs to know where in a line the emoji are and where the
## letters are.

import std/[sets, strutils, unicode]
import frq/emoji

const tones = [0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF]
  ## The five skin-tone modifiers.
  ##
  ## The catalogue leaves toned variants out on purpose — they multiply it by
  ## five and say nothing a reaction needs to say — but the pack has a picture
  ## for every one and falls back to the untoned picture where it has none. So
  ## a tone is stripped for the lookup and kept for the drawing.

type
  RunKind* = enum gkText, gkEmoji
  GlyphRun* = object
    kind*: RunKind
    value*: string

var
  pack {.threadvar.}: HashSet[string]
  starts {.threadvar.}: HashSet[Rune]
  scanLimit {.threadvar.}: int
  built {.threadvar.}: bool

proc build() =
  ## The lookup tables, made once.
  ##
  ## `pack` is every glyph there is a picture for, which is exactly the
  ## catalogue — a codepoint the pack has missed would be swapped out of the
  ## text for a picture that does not exist and drawn as the same tofu by a
  ## longer road. `starts` is their first runes, so a message with no emoji in
  ## it — which is nearly all of them — costs one set lookup per character and
  ## no substrings at all.
  if built: return
  built = true
  pack = initHashSet[string]()
  starts = initHashSet[Rune]()
  var longest = 1
  for e in catalog:
    pack.incl e.glyph
    let rs = e.glyph.toRunes
    if rs.len > 0: starts.incl rs[0]
    if rs.len > longest: longest = rs.len
  # Plus room for the tones the catalogue itself leaves out. A family is one
  # glyph made of four people, three joiners and a tone each, so the scan
  # cannot assume a cluster is short.
  scanLimit = longest + 5

func untoned(rs: seq[Rune]): string =
  for r in rs:
    if r.int32 notin tones: result.add $r

proc emojiAt(rs: seq[Rune], i: int): string =
  ## The longest emoji the pack knows that starts at `i`, or "".
  ##
  ## Longest first, because the short one is a prefix of the long one: 👨 is
  ## the head of 👨‍👩‍👧, and taking the man would leave his family as three
  ## more glyphs and two tofu joiners.
  var len = min(scanLimit, rs.len - i)
  while len > 0:
    var s = ""
    for k in i ..< i + len: s.add $rs[k]
    if s in pack or untoned(rs[i ..< i + len]) in pack:
      return s
    len -= 1
  ""

proc runs*(text: string): seq[GlyphRun] =
  ## `text` as alternating text and emoji runs, in order.
  ##
  ## An emoji run is one glyph: a node draws one picture, so two emoji side by
  ## side are two runs and not one.
  build()
  let rs = text.toRunes
  var buf = ""
  var i = 0
  while i < rs.len:
    var hit = ""
    if rs[i] in starts: hit = emojiAt(rs, i)
    if hit.len > 0:
      if buf.len > 0:
        result.add GlyphRun(kind: gkText, value: buf)
        buf = ""
      result.add GlyphRun(kind: gkEmoji, value: hit)
      i += hit.toRunes.len
    else:
      buf.add $rs[i]
      i += 1
  if buf.len > 0:
    result.add GlyphRun(kind: gkText, value: buf)

func hasEmoji*(rs: seq[GlyphRun]): bool =
  ## Whether any run is a picture — which is what decides between a plain
  ## label and a row that has to mix the two.
  for r in rs:
    if r.kind == gkEmoji: return true
  false

proc pickerEmoji*(search, group: string): seq[Emoji] =
  ## What the picker is showing: the popular row, one group, or whatever the
  ## search matches — by name, so "cat" finds the cat and the cat face, and by
  ## the glyph itself, so pasting one finds it.
  let q = search.strip().toLower()
  if q.len > 0:
    for e in catalog:
      if q in e.name.toLower() or q in e.glyph: result.add e
  elif group.len > 0:
    for e in catalog:
      if e.group == group: result.add e
  else:
    # A blank group is no group: the popular row is what nothing selected
    # means, and an empty string would filter the catalogue down to nothing.
    for g in popular:
      result.add Emoji(glyph: g, name: g, group: "")
