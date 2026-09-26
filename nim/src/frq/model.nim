## What a message and a room are.
##
## The types the rest of the port hangs off, transcribed from the shapes
## `frq.cells` holds and `frq.rooms` reads. Kept as one module because they
## are one idea: a room is a list of messages and the bookkeeping about how
## far it has been read.
##
## Fields that are `Option` in spirit are spelled as a value plus a `has`
## flag rather than `Option[T]`, for one reason: these cross the FFI as JSON,
## and a missing key and a null key are the same thing on the other side. An
## Option would have to be unwrapped at every boundary anyway.

import std/[options, strutils, tables]

type
  TaskEvent* = object
    ## A signed `freeq.at/act` event carried in a TAGMSG.  Its companion
    ## PRIVMSG is the visible line; this is the structured half that gives
    ## that line a task-card treatment.
    id*: string
    taskId*: string
    kind*: string
    verb*: string
    title*: string
    offeredTo*: string
    caps*: string
    note*: string
    context*: string

  Reaction* = object
    ## An emoji and who put it there. The nicks are a set in the Clojure; a
    ## seq here, kept ordered, because the order is what the pills are drawn
    ## in and a set would have thrown it away.
    emoji*: string
    nicks*: seq[string]

  Message* = object
    id*: string           ## the server's msgid, "" until it echoes back
    localId*: string      ## what this client called it before then
    editIds*: seq[string] ## every msgid this line has worn — see `answersTo`
    frm*: string
    text*: string
    at*: int64            ## epoch MILLISECONDS, 0 where the line carried none
                          ## Milliseconds because `clock.parseTimeTag` answers
                          ## in them and every clock function takes them. The
                          ## first draft of this said seconds and the day
                          ## headings quietly stopped appearing.
    system*: bool         ## a join/part/notice rather than something said
    mention*: bool
    edited*: bool
    replyTo*: string      ## the id this answers, "" for a line answering none
    reactions*: seq[Reaction]
    imageUrl*: string     ## the first picture link in the text, "" for none
    account*: string
      ## The sender's DID, off the `account` tag. The only identity a client
      ## is given: a nick is whatever someone chose today, and the hostmask
      ## carries eight characters of a DID, too few to resolve.
    avatar*: string       ## their thumbnail, once a profile has been fetched
    pending*: bool        ## sent, not yet echoed
    room*: string
      ## Which room this was said in. Empty on a stored message — a room
      ## already knows its own name — and filled in by `recentEverywhere`,
      ## where a line taken out of its conversation no longer says for itself.
    task*: TaskEvent
      ## Empty unless this is the visible companion of a task action.

  Room* = object
    ## A buffer: a channel or a DM. Named Room rather than Channel because
    ## Nim's `system.Channel` is the thread-safe queue `conn.nim` uses, and a
    ## type that shadows it here would be a confusing thing to debug.
    name*: string
    messages*: seq[Message]
    unread*: int
    mention*: bool
    joined*: bool
    joining*: bool
    heard*: bool
      ## Whether any conversation has arrived since our own last JOIN here —
      ## which is how this client tells a JOIN that replayed the backlog from
      ## one that did not. freeq replays on a real join, but a reconnect that
      ## reclaims a ghost session, or attaches beside another device on the
      ## same account, sends JOIN and NAMES with no backlog between them.
    users*: Table[string, string]
      ## nick → mode prefix ("" for none). A table and not a list because the
      ## people panel sorts ops first and a MODE has to find one person.
    namesAcc*: Table[string, string]
      ## The 353 replies so far. Pending rather than live: NAMES arrives over
      ## as many lines as it takes and ends with 366, and replacing `users` on
      ## each would empty the panel and refill it a name at a time.
    topic*: string
    accessed*: int64      ## when this reader last opened it
    lastActivity*: int64
    lastReadId*: string
    lastReadAt*: int64
    peerDid*: string      ## for a DM, who the other side is
    taskEvents*: Table[string, TaskEvent]
      ## event id → TAGMSG payload, held until its companion line arrives.
    taskTitles*: Table[string, string]
      ## opener id → title. Follow-up events name the opener, not its title.

func initMessage*(frm, text: string): Message =
  Message(frm: frm, text: text)

func initRoom*(name: string): Room =
  Room(name: name, taskEvents: initTable[string, TaskEvent](),
       taskTitles: initTable[string, string]())

# ------------------------------------------------------------------- naming

func dm*(name: string): bool =
  ## Whether a buffer is a conversation with a person rather than a room.
  ## Every channel name starts with `#`; what does not is somebody's nick.
  name.len > 0 and not name.startsWith("#")

func rowId*(m: Message): string =
  ## What this client calls a line: the server's name for it where there is
  ## one, and the name it was given here where there is not.
  ##
  ## freeq tags a message with a msgid and that is a line's identity
  ## everywhere it matters — a reply points at one, an edit rewrites one, a
  ## reaction lands on one. But not every line arrives with one: a replayed
  ## backlog can come with no tags at all, and a line this client has just
  ## sent has none until the server echoes it back. Those lines are not
  ## nameless to the reader — they are on the screen — so they get a local id
  ## made out of what they are. It is never sent.
  if m.id.len > 0: m.id else: m.localId

func answersTo*(m: Message, id: string): bool =
  ## Whether `id` names this line — by any of the names it has had.
  ##
  ## `rowId` is what this client calls a line; this is what everybody else may
  ## call it. A message keeps the id it was born with through every revision,
  ## but the server gives each revision a msgid of its own, and anyone
  ## replying to a line already rewritten answers the wording in front of them
  ## — so the reply names the revision rather than the original. Both are this
  ## message, so both find it.
  ##
  ## The local name counts too: a line just sent has no msgid until the echo,
  ## and its own reply chip points at the local id until then.
  if id.len == 0: return false
  id == m.id or id == m.localId or id in m.editIds

func messageById*(ch: Room, id: string): Option[Message] =
  ## The message `id` names, if this buffer still holds it.
  for m in ch.messages:
    if m.answersTo(id): return some(m)
  none(Message)

func indexById*(ch: Room, id: string): int =
  ## Where it is, or -1. Separate from `messageById` because scrolling wants
  ## the position and reading wants the value, and returning a copy to find an
  ## index would be the wrong way round.
  for i, m in ch.messages:
    if m.answersTo(id): return i
  -1
