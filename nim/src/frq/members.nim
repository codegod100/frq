## Who is in a channel, and what the server says about them.
##
## From `common/frq/members.cljc`. The membership is a nick → mode-prefix
## table rather than a list of names, because the panel sorts ops first and a
## MODE has to find one person among many.

import std/[algorithm, sequtils, strutils, tables]

const
  modePrefixes* = "~&@%+"
    ## The characters a server puts in front of a nick in NAMES, and in the
    ## same order the panel sorts them: owner, admin, op, half-op, voice.

  modeLetters = {'q': "~", 'a': "&", 'o': "@", 'h': "%", 'v': "+"}.toTable

type
  Member* = object
    nick*: string
    prefix*: string

func splitPrefix*(entry: string): (string, string) =
  ## One NAMES entry into `(prefix, nick)`. A nick never starts with one of
  ## these, so what is in front of it is a mode and not part of the name.
  if entry.len > 0 and entry[0] in modePrefixes:
    ($entry[0], entry[1 .. ^1])
  else:
    ("", entry)

proc withNames*(acc: var Table[string, string], names: string) =
  ## One 353 folded into the channel's pending list.
  ##
  ## Pending rather than live: the reply comes in as many lines as it takes
  ## and ends with 366, and replacing the list on each of them would empty the
  ## panel and refill it a name at a time.
  for entry in names.split(' '):
    if entry.strip().len == 0: continue
    let (prefix, nick) = splitPrefix(entry)
    if nick.len > 0: acc[nick] = prefix

proc withMode*(users: var Table[string, string], modes: string,
               args: seq[string]) =
  ## A channel MODE, for the letters that change how someone is listed.
  ##
  ## `args` is whoever the modes were applied to, in order; anything else in
  ## the mode string — a key, a limit, a ban — names no member and is skipped.
  ## A mode that takes an argument without naming a member still eats one, and
  ## reading the next letter's nick out of the wrong place would put a mode on
  ## a stranger, so only the setting form takes one.
  var adding = true
  var i = 0
  for c in modes:
    case c
    of '+': adding = true
    of '-': adding = false
    else:
      if c in modeLetters:
        if i < args.len:
          let nick = args[i]
          if users.hasKey(nick):
            users[nick] = if adding: modeLetters[c] else: ""
        i += 1
      elif adding:
        # Takes an argument but names nobody — a key or a limit. Eat it, or
        # the next letter reads somebody else's nick.
        i += 1

func prefixRank(prefix: string): int =
  ## Where a prefix sorts. No prefix is last, which is why this is not simply
  ## the index.
  let i = modePrefixes.find(if prefix.len > 0: prefix[0] else: '\0')
  if i < 0: modePrefixes.len else: i

func memberList*(users: Table[string, string]): seq[Member] =
  ## Ops first and then alphabetically — the order every other client lists
  ## them in, and the one a reader scanning for a name expects.
  for nick, prefix in users:
    result.add Member(nick: nick, prefix: prefix)
  result.sort(proc (a, b: Member): int =
    let ra = prefixRank(a.prefix)
    let rb = prefixRank(b.prefix)
    if ra != rb: cmp(ra, rb)
    else: cmp(a.nick.toLowerAscii, b.nick.toLowerAscii))

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

func completeNick*(text: string, nicks: seq[string]): (string, bool) =
  ## `text` with its last word completed against `nicks`. The bool is whether
  ## anything was completed at all.
  ##
  ## What Tab does in every IRC client, and the rules are theirs. One match is
  ## taken whole. Several are taken as far as they agree — the reader types
  ## another letter and asks again, rather than being given somebody at
  ## random. None leaves the draft alone.
  ##
  ## A name at the start of a line is addressed, so it gets `nick: `; anywhere
  ## else it is mentioned mid-sentence and gets a plain space. That is the
  ## convention freeq's own messages already follow.
  ##
  ## Case is ignored when matching and the nick's own case is what lands:
  ## people type `nan<tab>` and mean `nandi.uk`.
  let cut = max(text.rfind(' '), text.rfind('\n')) + 1
  let word = text[cut .. ^1]
  if word.len == 0: return (text, false)

  let lower = word.toLowerAscii
  var matches = nicks.filterIt(it.toLowerAscii.startsWith(lower))
  if matches.len == 0: return (text, false)
  matches.sort()

  let done =
    if matches.len == 1: matches[0] & (if cut == 0: ": " else: " ")
    else: commonPrefix(matches)
  if done.len <= word.len: return (text, false)
  (text[0 ..< cut] & done, true)
