## A line in the compose box that starts with `/`: a command, not something
## said.
##
## Parsed here and carried out in `reducer`, because what a command *is* is a
## question about a string and what it *does* is a question about the
## connection. This half has no state and no socket, so it is tested on its
## own.
##
## `//` escapes the slash: `//shrug` is the line `/shrug`, said. And a
## command this client does not know is not refused but sent as it was typed,
## uppercased — `/whois alice` is `WHOIS alice` — which is what every IRC
## client has done since there were IRC clients.

import std/strutils

type
  CommandKind* = enum
    ckNone      ## not a command: say the line
    ckJoin, ckPart, ckMsg, ckQuery, ckMe, ckNick, ckTopic, ckQuit, ckHelp
    ckRaw       ## `/quote`, `/raw`, and anything not named above
    ckUsage     ## a known command missing what it needs; `text` says what

  Command* = object
    kind*: CommandKind
    target*: string
      ## The channel or nick it acts on, where it takes one.
    text*: string
      ## The rest: what to say, a reason, a topic, the raw line, or the usage.

  CommandHelp* = tuple[name, args, does: string]

const commandHelp*: seq[CommandHelp] = @[
  ("join", "#channel [key]", "join a channel and open it"),
  ("part", "[#channel] [reason]", "leave this channel, or the one named"),
  ("msg", "nick message", "send a private message"),
  ("query", "nick [message]", "open a conversation with someone"),
  ("me", "action", "describe what you are doing"),
  ("nick", "newnick", "change your nickname"),
  ("topic", "[text]", "show or set this channel's topic"),
  ("quit", "[reason]", "disconnect"),
  ("quote", "LINE", "send a raw IRC line (also /raw)"),
  ("help", "", "list these commands")]

func commandNames*(): seq[string] =
  ## Every command as Tab completes it, slash included.
  for c in commandHelp: result.add "/" & c.name
  result.add "/raw"

func helpLines*(): seq[string] =
  for c in commandHelp:
    result.add "/" & c.name & (if c.args.len > 0: " " & c.args else: "") &
               " — " & c.does
  result.add "Anything else after a / is sent to the server as it is."

func usage(name: string): Command =
  for c in commandHelp:
    if c.name == name:
      return Command(kind: ckUsage, text: "Usage: /" & c.name &
                     (if c.args.len > 0: " " & c.args else: ""))
  Command(kind: ckUsage, text: "Usage: /" & name)

func splitWord(s: string): (string, string) =
  ## The first word and everything after the whitespace that follows it.
  let s = s.strip(trailing = false)
  var i = 0
  while i < s.len and s[i] notin Whitespace: i += 1
  (s[0 ..< i], s[i .. ^1].strip(trailing = false))

func isCommand*(text: string): bool =
  text.len > 1 and text[0] == '/' and text[1] != '/' and
    text[1] notin Whitespace

func unescapeSlash*(text: string): string =
  ## `//x` said as `/x`; anything else unchanged.
  if text.startsWith("//"): text[1 .. ^1] else: text

func parseCommand*(text: string, current = ""): Command =
  ## `text` as the reader typed it, `current` the open room or "".
  if not text.isCommand: return Command(kind: ckNone)
  let (word, after) = splitWord(text[1 .. ^1])
  let name = word.toLowerAscii
  let rest = after.strip(leading = false)
  case name
  of "join", "j":
    let (chan, key) = splitWord(rest)
    if chan.len == 0: return usage("join")
    let target = if chan[0] in {'#', '&'}: chan else: "#" & chan
    Command(kind: ckJoin, target: target, text: key)
  of "part", "leave":
    let (first, after) = splitWord(rest)
    if first.len > 0 and first[0] in {'#', '&'}:
      Command(kind: ckPart, target: first, text: after)
    elif current.len == 0: usage("part")
    else: Command(kind: ckPart, target: current, text: rest)
  of "msg", "privmsg":
    let (who, said) = splitWord(rest)
    if who.len == 0 or said.len == 0: return usage("msg")
    Command(kind: ckMsg, target: who, text: said)
  of "query", "q":
    let (who, said) = splitWord(rest)
    if who.len == 0: return usage("query")
    Command(kind: ckQuery, target: who, text: said)
  of "me":
    if rest.len == 0: return usage("me")
    Command(kind: ckMe, target: current, text: rest)
  of "nick":
    let (fresh, _) = splitWord(rest)
    if fresh.len == 0: return usage("nick")
    Command(kind: ckNick, target: fresh)
  of "topic":
    let (first, after) = splitWord(rest)
    if first.len > 0 and first[0] in {'#', '&'}:
      Command(kind: ckTopic, target: first, text: after)
    elif current.len == 0 or not current.startsWith('#'): usage("topic")
    else: Command(kind: ckTopic, target: current, text: rest)
  of "quit", "disconnect":
    Command(kind: ckQuit, text: rest)
  of "help", "commands", "?":
    Command(kind: ckHelp)
  of "quote", "raw":
    if rest.len == 0: return usage("quote")
    Command(kind: ckRaw, text: rest)
  else:
    Command(kind: ckRaw,
            text: word.toUpperAscii & (if rest.len > 0: " " & rest else: ""))

const actionMark = "\x01ACTION"

func actionLine*(text: string): string =
  ## What `/me` puts on the wire: a CTCP ACTION.
  actionMark & " " & text & "\x01"

func ctcpAction*(text: string): (string, bool) =
  ## A received line that is an ACTION, as the action alone and `true`; any
  ## other line unchanged and `false`. The closing `\x01` is optional on the
  ## wire, and some clients leave it off.
  if not text.startsWith(actionMark): return (text, false)
  var body = text[actionMark.len .. ^1]
  if body.endsWith('\x01'): body.setLen(body.len - 1)
  if body.startsWith(' '): body = body[1 .. ^1]
  (body, true)
