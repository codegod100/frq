## Message text as alternating text and link runs.
##
## From the bottom of `common/frq/screens/chat.cljc`. Pulled into a module of
## its own because it is the one part of that screen that is pure string
## work, and it is the part most worth testing on its own.
##
## Runs because a link has to be styled and clickable on its own. They are
## laid out as one inline row — a paragraph — rather than stacked: stacking
## gave every link a line of its own, and a plain wrapping row measures each
## label against the row's width rather than the column's, which is what
## drags long URLs off the left edge.

import std/strutils

type
  RunKind* = enum rkText, rkLink
  Run* = object
    kind*: RunKind
    value*: string

func trimTrailingPunctuation*(url: string): string =
  ## A URL at the end of a sentence would otherwise keep the sentence's
  ## punctuation. A closing bracket only counts as trailing when the URL does
  ## not open one itself, which is what keeps a wikipedia-style path intact.
  result = url
  while result.len > 0:
    let c = result[^1]
    if c in {'.', ',', ';', ':', '!', '?'}:
      result.setLen(result.len - 1)
    elif c == ')' and '(' notin result:
      result.setLen(result.len - 1)
    else:
      break

func urlAt(text: string, start: int): (int, int) =
  ## Where the next `http://` or `https://` run begins and ends, or (-1, -1).
  ## Hand-rolled rather than a regex for the reason the Clojure's time-tag
  ## parser is: this runs once per message of a hundred-message backlog.
  var i = start
  while i < text.len:
    if text[i] == 'h' and
       (text.continuesWith("http://", i) or text.continuesWith("https://", i)):
      var j = i
      while j < text.len and text[j] notin {' ', '\t', '\n', '\r', '<', '>', '"'}:
        j += 1
      return (i, j)
    i += 1
  (-1, -1)

func trimEnds(runs: seq[Run]): seq[Run] =
  ## The message's leading and trailing whitespace, off the runs that carry
  ## it.
  ##
  ## Only the two ends: every space between the runs is a space somebody typed
  ## between two words, and the paragraph they now share is where it shows.
  result = runs
  if result.len > 0 and result[0].kind == rkText:
    let v = result[0].value.strip(leading = true, trailing = false)
    if v.len > 0: result[0].value = v
    else: result.delete(0)
  if result.len > 0 and result[^1].kind == rkText:
    let v = result[^1].value.strip(leading = false, trailing = true)
    if v.len > 0: result[^1].value = v
    else: result.setLen(result.len - 1)

func textRuns*(text: string): seq[Run] =
  var pos = 0
  while pos < text.len:
    let (at, stop) = urlAt(text, pos)
    if at < 0:
      if pos < text.len:
        result.add Run(kind: rkText, value: text[pos .. ^1])
      break
    if at > pos:
      result.add Run(kind: rkText, value: text[pos ..< at])
    let url = trimTrailingPunctuation(text[at ..< stop])
    result.add Run(kind: rkLink, value: url)
    # Past the trimmed URL, not the raw one: the punctuation that was trimmed
    # is text and belongs in the next run.
    pos = at + url.len
  result = trimEnds(result)

func firstImageUrl*(text: string): string =
  ## The first picture link in a message, or "".
  ##
  ## PNG only, which is what the preview can draw. The link is left in the
  ## text either way — a preview is an addition to the message, not a
  ## replacement for what was said.
  for r in textRuns(text):
    if r.kind == rkLink:
      let low = r.value.toLowerAscii
      if low.endsWith(".png") or low.contains("/media/"):
        return r.value
  ""
