## The IRC wire format, as text. No socket, no host, no platform.
##
## A transcription of `common/frq/irc/parse.cljc`, which stays where it is
## until the Dart binding for this has been proven against it — see
## ../../README.md. The rules here are IRCv3's and the comments explaining
## *why* a rule is fiddly are kept from the original rather than rewritten,
## because they record bugs that were actually paid for.

import std/strutils

type
  IrcLine* = object
    ## An IRC line, taken apart. `raw` is what actually arrived, kept so a
    ## reader can say that rather than what we made of it — a tag the server
    ## dropped is invisible in every other field.
    raw*: string
    tags*: string        ## "" where the line carried none
    hasTags*: bool       ## distinguishes no tags at all from an empty "@ "
    account*: string
    hasAccount*: bool
    prefix*: string
    hasPrefix*: bool
    command*: string
    params*: seq[string]

func unescapeTag*(v: string): string =
  ## An IRCv3 tag value with its escapes undone.
  ##
  ## `\:` is a semicolon, `\s` a space, and `\\`, `\r` and `\n` themselves —
  ## the escaping exists because `;` separates tags and a space ends them. It
  ## matters for any value that can contain either: a reaction tally is
  ## `emoji:nick;emoji:nick` on the wire and arrives with every one of those
  ## semicolons written `\:`, so a reader that skips this step sees one tally
  ## where there were three, and counts to match.
  result = newStringOfCap(v.len)
  var i = 0
  while i < v.len:
    if v[i] == '\\' and i + 1 < v.len:
      result.add(case v[i + 1]
                 of ':': ';'
                 of 's': ' '
                 of 'r': '\r'
                 of 'n': '\n'
                 else: v[i + 1])
      i += 2
    else:
      result.add v[i]
      i += 1

func escapeTagValue*(v: string): string =
  ## The inverse, for a tag this client sends. An emoji needs none of it; a
  ## message id could, and the cost of being right is a pass over a short
  ## string.
  ##
  ## One pass rather than the original's five chained replaces, which is not
  ## an optimisation but a correctness fix waiting to happen: replacing `\`
  ## with `\\` first and `;` with `\:` second is only safe because of the
  ## order, and a sixth rule inserted in the wrong place would double-escape.
  result = newStringOfCap(v.len)
  for c in v:
    case c
    of '\\': result.add "\\\\"
    of ';': result.add "\\:"
    of ' ': result.add "\\s"
    of '\r': result.add "\\r"
    of '\n': result.add "\\n"
    else: result.add c

func tagValue*(tags, key: string): (string, bool) =
  ## One IRCv3 tag's value, unescaped, and whether it was there at all.
  ##
  ## A tag written with no value and one written `key=` say the same thing,
  ## which IRCv3 spells out and which this used to disagree with: the bare
  ## form fell through as absent and the empty one came back as "". A caller
  ## asks whether a fact is there, and an empty string is a fact that is
  ## there — which is how a `+reply=` on a line answering nothing put a reply
  ## chip above it, pointing at a message no id could find.
  ##
  ## So an empty value reads as absent, exactly as the Clojure did through
  ## `not-empty`. The bool is that answer; the string is meaningless when it
  ## is false.
  for pair in tags.split(';'):
    let eq = pair.find('=')
    let k = if eq < 0: pair else: pair[0 ..< eq]
    if k == key:
      let v = if eq < 0: "" else: unescapeTag(pair[eq + 1 .. ^1])
      return (v, v.len > 0)
  ("", false)

func nickOf*(prefix: string): string =
  ## The nick half of a `nick!user@host` prefix.
  let i = prefix.find('!')
  if i < 0: prefix else: prefix[0 ..< i]

func accountOf(tags: string): (string, bool) =
  ## The `account` tag, raw rather than unescaped — which is what the Clojure
  ## regex did, and is kept so the two agree byte for byte. A handle has
  ## nothing in it that needs escaping, so the two only differ on input no
  ## server sends.
  for pair in tags.split(';'):
    let eq = pair.find('=')
    if eq >= 0 and pair[0 ..< eq] == "account":
      return (pair[eq + 1 .. ^1], true)
    elif eq < 0 and pair == "account":
      return ("", false)
  ("", false)

func parseLine*(line: string): IrcLine =
  ## An IRC line into its parts. The trailing parameter (after " :") keeps its
  ## spaces; everything before it splits on whitespace.
  ##
  ## IRCv3 tags come first when there are any. A connection that negotiates
  ## CAP gets them where a bare one does not — which is why a client that
  ## ignores them looks fine as a guest and goes silent once it authenticates.
  result.raw = line.strip(leading = false, trailing = true)
  var rest = result.raw

  if rest.startsWith("@"):
    let i = rest.find(' ')
    if i < 0:
      # No space after the tags: the whole line was tags and nothing else.
      # Clojure's `subs` would throw on the nil index here; answering with an
      # empty remainder is what the caller can actually use.
      result.tags = rest[1 .. ^1]
      result.hasTags = true
      rest = ""
    else:
      result.tags = rest[1 ..< i]
      result.hasTags = true
      rest = rest[i .. ^1].strip(leading = true, trailing = false)

  if result.hasTags:
    (result.account, result.hasAccount) = accountOf(result.tags)

  if rest.startsWith(":"):
    let i = rest.find(' ')
    if i < 0:
      result.prefix = rest[1 .. ^1]
      result.hasPrefix = true
      rest = ""
    else:
      result.prefix = rest[1 ..< i]
      result.hasPrefix = true
      rest = rest[i + 1 .. ^1]

  let i = rest.find(" :")
  let head = if i < 0: rest else: rest[0 ..< i]
  var parts: seq[string] = @[]
  for p in head.split(' '):
    if p.len > 0: parts.add p

  result.command = if parts.len > 0: parts[0].toUpperAscii else: ""
  result.params = if parts.len > 1: parts[1 .. ^1] else: @[]
  if i >= 0:
    result.params.add rest[i + 2 .. ^1]
