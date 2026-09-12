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
                :jolt [[glimmer.ratom :refer [atom]]])))

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
