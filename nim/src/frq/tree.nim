## The screen the state says, as the JSON a host paints — built only when
## something it is built from has changed.
##
## Both hosts ask for this on a timer, ten times a second, because nothing
## calls into them when a line arrives. Building it every time was cheap in
## C and was not in a browser: a busy room is half a megabyte of tree, and
## under `nim js` building it, stringifying it and handing it over as a
## JavaScript string was about a quarter of a second — more than the timer's
## whole period, so the page never had an idle moment to take a keystroke in.
##
## So the state the last tree came from is kept, and an unchanged state gets
## the same JSON back. A whole-state comparison rather than a flag every
## mutation has to remember to set: a missed flag is a screen that does not
## move, and this cannot miss one.

import std/[json, strutils]
import frq/[cells, clock, reducer, ui]
import frq/screens/connect as scConnectScreen
import frq/screens/chats as scChatsScreen
import frq/screens/chat as scChatScreen
import frq/screens/settings as scSettingsScreen

var
  treeJson*: string
    ## The last tree built, which is the current one whenever `refresh` has
    ## just said so. Read it rather than copy it: it is the size of a room.
  built = false
  shown: State
  shownDay: string

proc refresh*(): bool =
  ## Bring `treeJson` up to date, and say whether it had to be rebuilt.
  ##
  ## `drain` first, so the tree is built after every line that had arrived
  ## when it was asked for — that is the whole of the polling model.
  drain()
  # The day, because "Today" and "Yesterday" are the only things on any
  # screen that the state does not hold: they move at midnight on their own.
  let today = day(nowMs())
  # The draft, because a keystroke does not need a tree: the reader's box
  # already holds what they typed. When the core rewrites the draft it moves
  # `draftRev`, which is compared.
  let typed = app.draft
  app.draft = shown.draft
  let same = built and today == shownDay and app == shown
  app.draft = typed
  if same: return false

  let connected = app.status.startsWith("Connected")
  let node =
    case app.screen
    of scChat: scChatScreen.chatScreen(app, connected)
    of scChats: scChatsScreen.chatsScreen(app, connected)
    of scDms: scChatsScreen.dmsScreen(app, connected)
    of scDiscover: scSettingsScreen.discoverScreen(app)
    of scSettings: scSettingsScreen.settingsScreen(app, connected, true)
    of scConnect: scConnectScreen.connectScreen(app)
  treeJson = $node.toJson
  shown = app
  shownDay = today
  built = true
  true

proc input*(event: string) =
  ## An event that wants no tree back: a keystroke in a field that carries a
  ## revision. See `ui.entry`. The next `refresh` builds one if anything
  ## besides the draft moved.
  try:
    dispatch(parseJson(event))
  except CatchableError:
    discard
