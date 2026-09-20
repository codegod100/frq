## Every piece of state the screens read.
##
## `common/frq/cells.cljc`, as one record. The Clojure holds 44 separate atoms
## because a screen there watches individual cells and re-renders on the ones
## it read; here the whole tree is rebuilt from the whole state on every
## event, so the grain that mattered there buys nothing and one record is
## easier to reason about.
##
## The comments are kept from the original wherever they record a decision,
## because they are the reason a field is shaped the way it is rather than
## documentation of what it obviously holds.

import std/tables
import frq/[model]

type
  Screen* = enum
    scConnect = "connect", scChats = "chats", scChat = "chat",
    scDiscover = "discover", scSettings = "settings"

  AuthMode* = enum
    amGuest = "guest", amBluesky = "bluesky", amAppPassword = "app-password"

  UploadStatus* = enum
    usUploading = "uploading", usReady = "ready"

  Attachment* = object
    ## The picture waiting to go out with the next line.
    ##
    ## Held apart from the draft rather than written into it. A link pasted
    ## into the entry is a line of unreadable text in the middle of whatever
    ## the reader was typing, and it puts their cursor somewhere they did not
    ## put it. The picture is a picture until it is sent; the draft stays
    ## theirs.
    ##
    ## One at a time — a second paste replaces the first, which is what a
    ## reader who pasted the wrong thing means by pasting the right one.
    has*: bool
    path*: string         ## the copy on disk, which is what the preview paints
    url*: string          ## where freeq serves it, once the upload has landed
    status*: UploadStatus

  EditTarget* = object
    ## The message the draft is a rewrite of, or absent when the box is being
    ## used for something new. Only the id is kept: what is being rewritten is
    ## in the box, and the line on screen is the thing it will replace.
    has*: bool
    room*: string
    id*: string

  ReplyTarget* = object
    ## The message the draft is answering. Held whole rather than as an id
    ## alone so the compose bar can say who is being answered without going
    ## looking for them.
    has*: bool
    id*, frm*, text*: string

  Lightbox* = object
    has*: bool
    path*, url*: string

  ReactTarget* = object
    ## What the emoji picker is choosing for. The picker is a panel over the
    ## compose bar rather than a screen: what is being reacted to has to stay
    ## in sight.
    has*: bool
    room*, id*: string

  ProfileView* = object
    ## Who is being looked at — `actor` is the DID or handle, absent for a
    ## guest.
    has*: bool
    nick*, actor*: string

  State* = object
    screen*: Screen
    status*: string
    error*: string
    hasError*: bool
    connecting*: bool

    # The connect form.
    authMode*: AuthMode
    formHost*, formPort*, formNick*: string
    formTls*: bool
    formHandle*, formAppPassword*: string

    # The durable half of an OAuth sign-in. The web-token beside it is
    # single-use, so a reconnect mints a fresh one from this rather than
    # replaying the old.
    hasSession*: bool
      ## Whether the host is holding a sign-in this client can connect with.
      ## A broker token on the desktop; an OAuth session in `localStorage` on
      ## the web, which the core never sees the whole of.

    brokerToken*: string
    apiBearer*: string
    loginUrl*: string     ## shown while the browser is open

    dids*: Table[string, string]
      ## Nick → DID, as the server reports it.
      ##
      ## freeq sends no `account` tag: the identity is in the hostmask, and
      ## the hostmask carries eight characters of a DID — too few to resolve.
      ## The whole of it comes back from `WHO` (352, in the realname field)
      ## and from `WHOIS` (330), and this is where it is kept. Without it a
      ## nick that is not itself a handle — `livecodelife`, `zapnap` — has no
      ## identity a profile can be looked up by, which is why opening one did
      ## nothing.

    # Rooms.
    rooms*: OrderedTable[string, Room]
    current*: string
    joinInput*: string
    search*: string

    picking*: bool
      ## Whether the host has been asked for a picture. Taken as it is read,
      ## so a dialog is opened once rather than on every frame.

    # The compose bar and its three companions.
    draft*: string
    editing*: EditTarget
    replyingTo*: ReplyTarget
    attachment*: Attachment

    # Chat chrome.
    showUsers*: bool
    hideChatList*: bool
    overview*: bool
    atPresent*: bool
    hideJoinPart*: bool
      ## Comings and goings, hidden or not. A quiet room reads better with
      ## them — they are how you notice someone arriving — and a busy one
      ## drowns in them, so it is the reader's call.

    # Emoji picker.
    emojiGroup*: string
    emojiSearch*: string
    reacting*: ReactTarget
    reactionHover*: ReactTarget

    # Navigation within a conversation.
    highlight*: string
    jumpTo*: string
      ## The message a "go to" is aiming at. Set for the frame that scrolls to
      ## it and taken off again — a target that stayed set would pin the view
      ## there and take scrolling away from the reader.
    jumpTick*: int
    overviewReturn*: string
      ## The room the reader was in when a line in the overview took them
      ## somewhere else. The strip is the one place in the app that moves you
      ## without your having asked to leave where you were, so it is the one
      ## place that owes you the way back.

    lightbox*: Lightbox
    savedTo*: string
      ## What the lightbox's Save has to say for itself: where a picture
      ## landed, or "failed". Saving is a file appearing somewhere off screen,
      ## so the one thing the reader needs back is where — a button that only
      ## stops looking pressed has told them nothing.
    savedFailed*: bool

    imagePicker*: string
    profileViewing*: ProfileView

    # The window, polled from the host.
    windowWidth*, windowHeight*: int
      ## The height is for the pictures in the conversation: a preview sized
      ## against the window is a picture on a laptop and a thumbnail on a
      ## phone, where one fixed height is only ever right on one of them.

const
  defaultHost* = "irc.freeq.at"
  defaultPort* = "6697"

  wideWidth* = 900
    ## Where the second pane starts paying for itself. Below this a 320pt list
    ## beside a conversation leaves the messages narrower than the phone
    ## layout they were written for.

  popularChannels*: seq[(string, string)] = @[
    ("#general", "General discussion"),
    ("#test", "Test channel"),
    ("#freeq", "freeq development & support"),
    ("#dev", "Programming & technology"),
    ("#music", "Music recommendations"),
    ("#random", "Off-topic chat")]

func initState*(): State =
  State(screen: scConnect,
        status: "Not connected",
        authMode: amGuest,
        formHost: defaultHost,
        formPort: defaultPort,
        formTls: true,
        formNick: "frq-guest",
        atPresent: true,
        rooms: initOrderedTable[string, Room]())

func wide*(s: State): bool =
  ## Past this the room list and the conversation are both on screen instead
  ## of taking turns.
  s.windowWidth >= wideWidth

func currentRoom*(s: State): Room =
  if s.current.len > 0 and s.rooms.hasKey(s.current): s.rooms[s.current]
  else: initRoom("")

var app* = initState()
  ## The one mutable thing. Named `app` rather than `state` because `state` is
  ## ambiguous against unittest's own inside a test module.
