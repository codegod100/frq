(ns frq.cells
  "The cells the connect screen reads, and the constants beside them.

  Moved out of `frq.state` so a screen can be shared: `frq.state` is 1,930
  lines that reach `frq.irc` and `frq.av` and will not compile under
  ClojureDart for a long time yet, but the cells themselves are atoms and
  atoms are portable. `frq.state` re-defs every name here, so its own thousand
  lines did not move and neither did anything reading `s/form-handle`.

  The reader conditional is the whole trick. On jolt these are glimmer ratoms
  — a component that derefs one re-renders when it changes, which is what the
  desktop's reconciler is built on. Under ClojureDart they are ordinary atoms,
  and `cljd.flutter`'s `:watch` does the same job from the other end. Neither
  compiler sees the other's require.

  jolt answers to `:jolt` and ClojureDart to `:cljd`; ClojureDart also has
  `:clj` always on, which is why neither branch is spelled that way."
  (:require #?@(:cljd []
                :jolt [[glimmer.ratom :refer [atom reaction]]])))

(def default-host "irc.freeq.at")
(def default-port "6697")

;; screen: :connect | :chats | :chat | :discover | :settings
(defonce screen (atom :connect))
(defonce status (atom "Not connected"))
(defonce error (atom nil))
(defonce connecting? (atom false))

(defonce form-host (atom default-host))
(defonce form-port (atom default-port))
;; TLS is the default; untick it for a server's plain :6667 listener
(defonce form-tls? (atom true))
(defonce form-nick (atom "frq-guest"))

;; Bluesky sign-in. The app password reaches the user's own PDS and nothing
;; else: freeq is handed the session token it mints, and verifies that token by
;; asking the same PDS. It is never written to disk.
(defonce auth-mode (atom :guest))         ; :guest | :bluesky | :app-password
(defonce form-handle (atom ""))
(defonce form-app-password (atom ""))
(defonce session (atom nil))              ; a pds-session or a web-token one

;; The durable half of an OAuth sign-in. The web-token beside it is single-use,
;; so a reconnect mints a fresh one from this rather than replaying the old.
; ------------------------------------------------------------------ rooms
;; name -> {:name :messages [{:from :text}] :unread n :joined? bool}
(defonce channels (atom {}))
(defonce current (atom nil))
(defonce join-input (atom ""))
(defonce search (atom ""))

(defonce broker-token (atom nil))
(defonce login-url (atom nil))            ; shown while the browser is open

;; ------------------------------------------------------------------- chat
;; What the conversation screen reads. The compose bar's three companions —
;; a reply, an edit and an attachment — are apart from the draft rather than
;; written into it: a link pasted into the box is a line of unreadable text in
;; the middle of whatever the reader was typing.

(defonce draft (atom ""))

;; The message the draft is a rewrite of, as `{:channel :id}`, or nil when the
;; box is being used for something new. Only the id is kept: what is being
;; rewritten is in the box, and the line on screen is the thing it will replace.
(defonce editing (atom nil))

;; The message the draft is answering, as {:id :from :text}, or nil. Held whole
;; rather than as an id alone so the compose bar can say who is being answered
;; without going looking for them.
(defonce replying-to (atom nil))

;; The picture waiting to go out with the next line, or nil:
;;
;;   {:path  the copy on disk, which is what the preview paints
;;    :url   where freeq serves it, once the upload has landed
;;    :status :uploading | :ready}
;;
;; Held apart from the draft rather than written into it. A link pasted into
;; the entry is a line of unreadable text in the middle of whatever the reader
;; was typing, and it puts their cursor somewhere they did not put it. The
;; picture is a picture until it is sent; the draft stays theirs.
;;
;; One at a time — a second paste replaces the first, which is what a reader
;; who pasted the wrong thing means by pasting the right one.
(defonce attachment (atom nil))

(defonce jump-tick (atom 0))

;; Whether the chat screen is showing who is in the channel. Off by default:
;; the panel costs the conversation a column, and the reader is here for the
;; conversation.
(defonce show-users? (atom false))

;; Whether the wide window is holding the chats list back, leaving the whole
;; row to the conversation. Only a wide window has anything to hide: below
;; `wide-width` the list and the conversation already take turns, and hiding
;; the list there would be hiding the only way to another room.
;;
;; Saved with the other settings rather than reset per launch: it is a choice
;; about how this screen is read, and a reader who wants the conversation
;; whole wants it whole again tomorrow.
(defonce hide-chat-list? (atom false))

;; Whether the conversation is sharing its room with the overview strip —
;; every channel's last lines in one list, under the one you are reading.
;; Saved for the same reason as the fold above it: it is a choice about how
;; this screen is laid out, and a layout a reader chose should be the one they
;; come back to.
(defonce overview? (atom false))

;; Whether the chat view is showing the newest line, and a counter the view
;; watches to be told to go back to it. A counter rather than a flag: a flag
;; would need clearing, and there is no frame in which to clear it.
(defonce at-present? (atom true))

;; --------------------------------------------------- picker, jump, window

(defonce emoji-group (atom nil))

;; What the picker is showing: the search box, and which group is on screen
;; when nothing has been typed. `nil` is the popular row it opens on.
(defonce emoji-search (atom ""))

;; The message a jump has just landed on. It outlives the scroll: arriving at a
;; screenful of messages says nothing about which one was asked for, so the one
;; that was answers for itself until the reader has had time to see it.
(defonce highlight (atom nil))

;; The message a "go to" is currently aiming at. Set for the frame that scrolls
;; to it and taken off again — a scroll target that stays set would pin the
;; view there and take scrolling away from the reader.
(defonce jump-to (atom nil))

;; The picture being looked at full size, or nil. Vidya's tree has no overlay,
;; so this is a screen of its own rather than a layer over the chat.
(defonce lightbox (atom nil))            ; {:path :url}

;; The room the reader was in when a line in the overview took them somewhere
;; else, or nil. The strip is the one place in the app that moves you without
;; you having asked to leave where you were — everything else is a room you
;; chose — so it is the one place that owes you the way back.
(defonce overview-return (atom nil))

;; The message the emoji picker is choosing for, as `{:channel :id}`, or nil
;; when it is closed. The picker is a panel over the compose bar rather than a
;; screen: what is being reacted to has to stay in sight.
(defonce reacting (atom nil))

;; The window's content height, polled beside the width and for the same
;; reason. What it is for is the pictures in the conversation: a preview sized
;; against the window is a picture on a laptop and a thumbnail on a phone,
;; where one fixed height is only ever right on one of them.
(defonce window-height (atom 0))

;; The window's content width in points, polled from the backend a few times a
;; second. The app is laid out for a phone-width window, and this is what lets
;; a wide one be more than a phone with margins: past `wide-width` the channel
;; list and the conversation are both on screen instead of taking turns.
(defonce window-width (atom 0))

;; ------------------------------------------------------------- derivation

(defonce ^:private derived-cells
  ;; One cell per question, kept for the session: a cell made afresh on every
  ;; render would add a watch to its source each time and never take it off.
  (atom {}))

(defn derived-value
  "The answer to one question about shared state, under `k`.

  A message row that read `highlight` itself was re-rendered whenever the
  highlight moved anywhere — every row in the backlog, for one jump. A
  reaction is recomputed on each such change, which is a comparison, but it
  wakes the rows that read it only when its answer changes.

  None of which applies under ClojureDart, where Flutter rebuilds the screen
  and diffs its own element tree: there is no subtree to wake, so the question
  is simply asked. That is the whole of the difference, and it is why this is
  a value rather than a cell — `@(derived k f)` could not be written once."
  [k f]
  #?(:cljd (f)
     :jolt (deref (or (get @derived-cells k)
                      (let [cell (reaction (f))]
                        (swap! derived-cells assoc k cell)
                        cell)))))

;; The pill the pointer is resting on, or nil — `{:id msgid :emoji glyph}`.
;; One at a time, and named by the message as well as the glyph: the same emoji
;; is a pill under many messages, and only the one under the pointer carries a
;; card.
(defonce reaction-hover (atom nil))

;; Comings and goings, hidden or not. A quiet room reads better with them —
;; they are how you notice someone arriving — and a busy one drowns in them,
;; so it is the reader's call. Only other people's: your own "Joined #chan" is
;; the answer to something you just did.
(defonce hide-join-part? (atom false))

(def popular-channels
  [["#general" "General discussion"]
   ["#test"    "Test channel"]
   ["#freeq"   "freeq development & support"]
   ["#dev"     "Programming & technology"]
   ["#music"   "Music recommendations"]
   ["#random"  "Off-topic chat"]])


;; joined as soon as the server sends 001

;; Where the picker is looking, or nil when it is closed. A path, so the
;; browsing is just this cell moving.
(defonce image-picker (atom nil))


;; ------------------------------------------------------------------ profiles

;; Who is being looked at, or nil — `{:nick :actor}`, where `actor` is the DID
;; or handle, and nil for a guest.
(defonce profile-viewing (atom nil))

;; The face the pointer is resting on, the same shape. A card is painted for
;; this one alone rather than hung under every avatar in the column.
(defonce profile-hovering (atom nil))

;; Bumped when a profile fetch lands, so the screen re-renders without
;; watching the cache map itself.
(defonce profile-tick (atom 0))

;; ------------------------------------------------------------- enumeration

(defn all-cells
  "Every cell above, for a backend that has to be told what to watch.

  glimmer needs no such list: a component that derefs a ratom is subscribed to
  it by the act of dereferencing, so the desktop hears about a change it never
  declared an interest in. `cljd.flutter` works from the other end — `:watch`
  names what a widget rebuilds for — and the phone kept that list in the
  widget, where it drifted: People, Overview and hide join/part each flipped
  the cell they were meant to flip and repainted nothing, because the cell was
  not named there.

  A function and not a `def`, which is the part ClojureDart makes you care
  about: a `def` becomes a Dart top-level variable, those initialise on first
  read, and a list nothing has read yet is still empty at the moment the
  watches are installed. Calling it also forces every cell it names.

  `tools/check-common.py` fails the build if this falls behind the
  definitions, because a list kept by hand is only as good as what checks it."
  []
  [screen status error connecting? form-host form-port form-tls? form-nick
   auth-mode form-handle form-app-password session channels current
   join-input search broker-token login-url draft editing replying-to
   attachment jump-tick show-users? hide-chat-list? overview? at-present?
   emoji-group emoji-search highlight jump-to lightbox overview-return
   reacting window-height window-width reaction-hover hide-join-part?
   image-picker profile-viewing profile-hovering profile-tick])
