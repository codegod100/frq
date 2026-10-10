## Tab in the compose box: the word at the caret, completed.
##
## `members.completeNick` is the one-shot rule — one match whole, several as
## far as they agree. This is the same rule with a memory, which is what lets
## a second Tab mean something: once the matches agree no further, Tab walks
## through them one at a time, and Shift-Tab walks back.
##
## The memory is the draft and the caret as Tab left them. Anything the
## reader does in between — a letter typed, the caret moved — makes the next
## Tab a fresh completion of whatever word is under the caret now.

import std/[algorithm, strutils, unicode]

type
  TabState* = object
    active*: bool
      ## Whether the last Tab changed anything. False leaves the draft alone.
    head*, tail*: string
      ## The draft before the word being completed, and after the caret.
    lead*: string
      ## An `@` the reader typed in front of a nick, kept where it was.
    atStart*: bool
      ## The word opens the line, so a nick there is addressed: `nick: `.
    matches*: seq[string]
    index*: int
      ## Which match is in the draft; -1 while it holds only what they share.
    text*: string
    caret*: int
      ## The draft and the caret (a byte offset) as this Tab left them.

func commonPrefix(ss: seq[string]): string =
  ## The longest string every one of `ss` starts with, ignoring case.
  if ss.len == 0: return ""
  result = ss[0]
  for s in ss[1 .. ^1]:
    var i = 0
    while i < min(result.len, s.len) and
          result[i].toLowerAscii == s[i].toLowerAscii:
      i += 1
    result = result[0 ..< i]

func render(st: TabState, word: string, whole: bool): string =
  ## The word as it goes into the draft. A whole nick at the start of a line
  ## is addressed and gets `: `; anything else whole gets a space, unless the
  ## text after the caret already starts with one.
  result = st.lead & word
  if not whole: return
  let addressed = not word.startsWith('#') and not word.startsWith('/')
  if st.atStart and st.lead.len == 0 and addressed: result.add ':'
  if not st.tail.startsWith(' '): result.add ' '

func place(st: var TabState, word: string, whole: bool) =
  let w = st.render(word, whole)
  st.text = st.head & w & st.tail
  st.caret = st.head.len + w.len
  st.active = true

func tabComplete*(text: string, caret: int, nicks, channels: seq[string],
                  prev: TabState, back = false,
                  commands: seq[string] = @[]): TabState =
  ## Tab pressed with the caret at byte offset `caret` of `text`.
  ##
  ## `nicks` in the order a cycle visits them — the caller puts whoever spoke
  ## last first, which is who a reader is most often answering. A word
  ## starting with `#` is matched against `channels` instead, and one starting
  ## with `/` at the very start of the line against `commands`.
  let caret = clamp(caret, 0, text.len)

  # A Tab straight after a Tab: the next match, or the previous one.
  if prev.active and prev.text == text and prev.caret == caret and
     prev.matches.len > 1:
    result = prev
    let n = prev.matches.len
    result.index =
      if prev.index < 0: (if back: n - 1 else: 0)
      elif back: (prev.index + n - 1) mod n
      else: (prev.index + 1) mod n
    result.place(prev.matches[result.index], true)
    return

  var cut = caret
  while cut > 0 and text[cut - 1] notin Whitespace: cut -= 1
  var word = text[cut ..< caret]
  result.head = text[0 ..< cut]
  result.tail = text[caret .. ^1]
  result.atStart = result.head.strip.len == 0
  if word.startsWith('@'):
    result.lead = "@"
    word = word[1 .. ^1]
  if word.len == 0: return

  let command = word.startsWith('/') and result.head.len == 0 and
                result.lead.len == 0
  let pool = if command: commands
             elif word.startsWith('#'): channels
             else: nicks
  let lower = word.toLowerAscii
  for c in pool:
    if c.toLowerAscii.startsWith(lower) and c notin result.matches:
      result.matches.add c
  if result.matches.len == 0: return

  if result.matches.len == 1:
    result.index = 0
    result.place(result.matches[0], true)
    return

  # Several: as far as they agree first, so a reader who knows the next
  # letter can type it. Only once that is all there is does Tab cycle.
  let shared = commonPrefix(result.matches)
  if shared.len > word.len:
    result.index = -1
    result.place(shared, false)
  else:
    result.index = if back: result.matches.len - 1 else: 0
    result.place(result.matches[result.index], true)

func byteOffset*(s: string, utf16: int): int =
  ## A caret as the host counts it — UTF-16 code units — as a byte offset
  ## into `s`. A caret inside a surrogate pair rounds forward.
  var units = 0
  var i = 0
  while i < s.len and units < utf16:
    let r = s.runeAt(i)
    units += (if r.int > 0xFFFF: 2 else: 1)
    i += s.runeLenAt(i)
  i

func utf16Offset*(s: string, bytes: int): int =
  ## The other way: a byte offset into `s` as UTF-16 code units.
  var i = 0
  while i < min(bytes, s.len):
    let r = s.runeAt(i)
    result += (if r.int > 0xFFFF: 2 else: 1)
    i += s.runeLenAt(i)

func byRecency*(users: seq[string], spoke: seq[string], me: string): seq[string] =
  ## `users` with whoever spoke most recently first, then the rest
  ## alphabetically. `spoke` is the room's senders, oldest first. Yourself
  ## last of all: nobody tabs to their own name, but it is not missing either.
  var seen: seq[string]
  for i in countdown(spoke.high, 0):
    let n = spoke[i]
    if n != me and n in users and n notin seen: seen.add n
  var rest: seq[string]
  for u in users:
    if u notin seen and u != me: rest.add u
  rest.sort(proc (a, b: string): int = cmp(a.toLowerAscii, b.toLowerAscii))
  result = seen & rest
  if me in users: result.add me
