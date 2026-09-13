(ns frq.state
  "Every cell the UI reads, and the reducers that write them.

  glimmer components re-render from ratoms, so the whole app state is a handful
  of `atom`s here; the IRC reader thread pushes into the same ones. `apply-msg!`
  is the only place a wire message turns into UI state."
  (:require [clojure.string :as str]
            [frq.rooms :as rooms]
            [frq.members :as members]
            [frq.reactions :as reactions]
            [frq.edits :as edits]
            [glimmer.ratom :as r :refer [atom]]
            [frq.actions :as actions]
            [frq.cells :as cells]
            [frq.replies :as replies]
            [jolt.host :as host]
            [frq.atproto :as atproto]
            [frq.av :as av]
            [frq.clock :as clock]
            [frq.emoji :as emoji]
            [frq.irc :as irc]
            ;; For the side effect: it installs the desktop crypto behind
            ;; `frq.crypto`, which the shared `frq.msgsig` signs through.
            [frq.crypto.openssl]
            [frq.msgsig :as msgsig]
            [frq.avatars :as avatars]
            [frq.media :as media]
            [frq.oauth :as oauth]
            [frq.platform :as platform]
            [frq.store :as store]
            [frq.upload :as upload]))

(def default-host cells/default-host)
(def default-port cells/default-port)

;; The cells the connect screen reads live in `frq.cells` now, so that screen
;; could move to common/ and be the same file on the phone. Re-defined here
;; rather than left to the callers: a thousand lines below this say
;; `@form-nick` and `@connecting?`, and none of them care which namespace the
;; atom was made in.
(def screen cells/screen)
;; Not in frq.cells: this holds the live IRC connection, which is jolt's
;; socket and a reader thread. The phone's equivalent is a dart:io Socket and
;; nothing shared could hold either.
(defonce conn (atom nil))
(def status cells/status)
(def error cells/error)
(def connecting? cells/connecting?)
(def form-host cells/form-host)
(def form-port cells/form-port)
(def form-tls? cells/form-tls?)
(def form-nick cells/form-nick)
(def auth-mode cells/auth-mode)
(def form-handle cells/form-handle)
(def form-app-password cells/form-app-password)
(def session cells/session)
(def broker-token cells/broker-token)
(def channels cells/channels)
(def current cells/current)
(def join-input cells/join-input)
(def search cells/search)
(def login-url cells/login-url)

(def popular-channels cells/popular-channels)

(def auto-join "#test")

;; How much backlog to ask for when the server did not volunteer any.
(def history-limit 100)

(def draft cells/draft)
(def replying-to cells/replying-to)

(defn reply-to! [m] (reset! replying-to (select-keys m [:id :from :text])))
(defn cancel-reply! [] (reset! replying-to nil))

(def editing cells/editing)

(def reacting cells/reacting)

(def emoji-search cells/emoji-search)
(def emoji-group cells/emoji-group)

(def lightbox cells/lightbox)

(def show-users? cells/show-users?)

(defn toggle-users! [] (swap! show-users? not))

(def hide-chat-list? cells/hide-chat-list?)

(declare save-prefs!)

(defn toggle-chat-list! []
  (swap! hide-chat-list? not)
  (save-prefs!))

(def overview? cells/overview?)

(defn toggle-overview! []
  (swap! overview? not)
  (save-prefs!))

(def overview-return cells/overview-return)

(declare open-channel!)

(defn leaving-for-overview!
  "Remember where we are, because a line in the strip is about to take us out
  of it. Nothing to remember if there is nowhere to go back to."
  []
  (reset! overview-return @current))

(defn overview-back!
  "Back to the room the strip took you out of.

  The room, and with it the place in it: the backlog's scroll is remembered
  under a name per conversation — see `messages-scroll-key` — so a backend
  that keeps a position per name lands back where the strip found you. One
  that only knows whether a viewport is new to it, as the Flutter side does,
  brings you back to the newest line instead; both beat the middle of the
  last room you were in, which is what one name for every room gave."
  []
  (when-let [room @overview-return]
    (reset! overview-return nil)
    (open-channel! room)))

(def window-width cells/window-width)

(def window-height cells/window-height)

;; Where the second pane starts paying for itself, shared with the other
;; backends — see `frq.cells/wide-width`.
(def wide-width cells/wide-width)

(defn wide?
  "True while the window has room for the list and a conversation at once."
  []
  (>= @window-width wide-width))

(defn chat-visible?
  "Whether the conversation in `current` is on screen.

  On a narrow window that is the chat screen alone. On a wide one the chats
  screen shows it too, in the pane beside the list — so this, and not the
  screen, is what decides whether an arriving line counts as unread."
  []
  (or (= :chat @screen)
      (and (wide?) (= :chats @screen))))

(def at-present? cells/at-present?)
(def jump-tick cells/jump-tick)

;; How a backend answers "did that scroll end at the end?".
;;
;; The window's scroll area says so itself — `:on-change` arrives with "end" —
;; and the terminal's does not: it reports the offset it was asked for and
;; never how far down the bottom is. What it does do is clamp, so a request
;; that came back smaller than it went out is a request that ran into the end.
;; Only a backend that can see that installs this; `scrolled!` is written for
;; both, and asks.
(defonce at-end-probe (atom nil))

(defn scrolled!
  "A viewport moved under the reader, to the offset `to`.

  For the backends whose scroll areas report a position rather than a place:
  where that leaves the reader is what `at-end-probe` is asked, and with
  nobody to ask, any scroll at all is a scroll away from the newest line."
  [to]
  (reset! at-present? (boolean (when-let [probe @at-end-probe] (probe to))))
  nil)

(defn jump-to-present!
  "Go back to the newest line.

  `at-present?` is set here rather than left to the view because not every
  backend can tell us: the window's scroll area reports where it ended up and
  corrects this on the next frame, and the terminal's does not report the
  bottom at all — so what a jump means for the button that asked for it is
  said here, once, for both."
  []
  (reset! at-present? true)
  (swap! jump-tick inc))
;; A counter rather than a clock: the list only needs their order, and a
;; monotonic tick cannot be surprised by the system time moving.
(def access-tick rooms/access-tick)

(def hide-join-part? cells/hide-join-part?)

;; Whether rooms.edn is the authority yet.
;;
;; It is not, the first time this version runs: freeq re-joins an authenticated
;; user's channels at registration, so on connect the server announces every
;; room it has you in — and a client that parted everything not already in its
;; file would walk out of all of them before the file had ever been told they
;; existed. So the first connect adopts what the server says and writes it
;; down, and every connect after that is the strict one.
(defonce room-list-owned? (atom false))

;; And whether this session is the adopting one, decided at 001.
(defonce ^:private adopting-rooms? (atom false))

(defn- save-prefs! []
  (future (store/save-prefs! (assoc (store/load-prefs)
                                    :hide-join-part? @hide-join-part?
                                    :hide-chat-list? @hide-chat-list?
                                    :overview? @overview?
                                    :room-list-owned? @room-list-owned?))))

(defn toggle-hide-join-part! []
  (swap! hide-join-part? not)
  (save-prefs!))

(defn restore-prefs!
  "Bring back the saved settings at startup."
  []
  (let [prefs (store/load-prefs)]
    (reset! hide-join-part? (boolean (:hide-join-part? prefs)))
    (reset! hide-chat-list? (boolean (:hide-chat-list? prefs)))
    (reset! overview? (boolean (:overview? prefs)))
    (reset! room-list-owned? (boolean (:room-list-owned? prefs)))
    prefs))

(defn connected? [] (some? @conn))

(declare channel-order room-records request-names!)

(defonce ^:private rooms-saved-at (atom 0))

(defn- remember-rooms!
  "Write the room records out: what rooms there are, in the order they were
  last used, and how much of each has been read.

  Off the caller's thread, because opening a room should not wait on a file.
  Throttled, because the marker moves on every line that arrives while a room
  is on screen and a busy channel would otherwise write the file per message —
  `force?` is for the moments worth paying for, which is a room being opened.

  A late write costs at most the handful of lines that arrived since the last
  one, shown unread again on the next run. That is the right way round: the
  marker never claims to have read more than it has."
  ([] (remember-rooms! false))
  ([force?]
   (let [now (clock/now-ms)]
     (when (or force? (> (- now @rooms-saved-at) 5000))
       (reset! rooms-saved-at now)
       (future (store/save-rooms! (room-records)))))))

(def dm? rooms/dm?)

(defn normalize-channel [s]
  (let [s (str/trim (or s ""))]
    (cond (str/blank? s) ""
          (str/starts-with? s "#") s
          :else (str "#" s))))

(def ^:private after-marker rooms/after-marker)

(def ^:private recount rooms/recount)

(def ^:private mark-read rooms/mark-read)

(def ^:private ensure-channel rooms/ensure-channel)

(defonce ^{:doc "Bumped whenever a fetched image becomes available, so the
  chat view re-renders without every message row watching the media cache."}
  media-tick (atom 0))

(defn local-id
  "A name for a line the server did not name.

  freeq tags a message with a `msgid` and that is a line's identity everywhere
  it matters — a reply points at one, an edit rewrites one, a reaction lands on
  one. But not every line arrives with one: a replayed backlog can come over
  with no tags at all, and a line this client has just sent has none until the
  server echoes it back.

  Those lines are not nameless to the reader, though. They are on the screen,
  they are in the overview, and pressing one should go to it. So they get a
  name made out of what they are: who said it, what it said, when, and where.
  Two lines identical in all four are the same line as far as anything this
  client does with one is concerned.

  `local-` because it is this client's alone, and it is never sent: the
  server knows only the names it gave out."
  [channel from text at]
  (str "local-" (hash [channel from text at])))

(defn push-message!
  "Append a line to a buffer, creating it if needed, and bump the unread count
  unless that buffer is the one on screen. Any image it links to is fetched in
  the background, as is the sender's avatar.

  The extras are what the message carried beyond its text: `:at` when it was
  said, from the server's own `time` tag where there is one, and `:did` who
  said it, from the `account` tag — an identity that outlasts whatever nick
  they are using today. `:id` names this message so a reply can point at it,
  and `:reply-to` is the one it answers. `:reactions` is what people have put
  on it already, which on a replayed backlog the server hands over in full."
  ([channel from text] (push-message! channel from text {}))
  ([channel from text {:keys [at did id reply-to reactions edited? edit-ids]}]
   (let [at (or at (clock/now-ms))
         ;; A name of our own where the server gave none. See `local-id`.
         mine (when-not id (local-id channel from text at))
         who (avatars/actor did from)
         ;; A room reaching the store matters more than the throttle does: a
         ;; connection joins every channel at once, and the writes for all but
         ;; the first would be five seconds away — long enough that quitting
         ;; straight after signing in is how a client forgets the rooms it just
         ;; joined. Read before the swap, so this is the arrival that made it.
         new-room? (not (contains? @channels channel))]
     (doseq [url (media/image-urls text)]
       (media/fetch! url #(swap! media-tick inc)))
     ;; The same tick: an avatar arriving is a picture arriving, and the chat
     ;; view already repaints on it.
     (when who (avatars/fetch! who #(swap! media-tick inc)))
     (swap! channels
            (fn [m]
              (let [m (ensure-channel m channel)
                    viewing? (and (chat-visible?) (= channel @current))
                    ;; And not a second copy of one we already hold: the
                    ;; server hands the same message over more than once, and
                    ;; `frq.rooms/seen-message?` is the whole of that rule —
                    ;; shared, because the Flutter half was appending every
                    ;; replay this drops.
                    seen? (rooms/seen-message? (get-in m [channel :messages])
                                               id from text @form-nick)]
                (cond
                  ;; The copy we already hold is the pre-edit one, and this is
                  ;; the server's collapsed row saying so. Same message, later
                  ;; word: take the text rather than the arrival order.
                  (and seen? edited?)
                  (assoc-in m [channel :messages]
                            (mapv (fn [msg]
                                    (if (= id (:id msg))
                                      (assoc msg :text text :edited? true
                                             :images (media/image-urls text))
                                      msg))
                                  (get-in m [channel :messages])))

                  seen? m

                  :else
                  (-> m
                    (update-in [channel :messages] conj
                               {:from from :text text :system? (= "*" from)
                                :actor who
                                :images (media/image-urls text)
                                :at at
                                ;; `:id` is what a reply points at, and
                                ;; `:reply-to` is what this one points at.
                                :id id :local-id mine :reply-to reply-to
                                ;; Any other msgid this same line answers to
                                ;; — a revision's. See `frq.rooms/answers-to?`.
                                :edit-ids (set (remove nil? edit-ids))
                                ;; The sender has since rewritten this line.
                                ;; Replay says so with a tag rather than by
                                ;; sending the revision, so a message can
                                ;; arrive already edited.
                                :edited? (boolean edited?)
                                ;; emoji -> the nicks who put it there
                                :reactions (or reactions {})})
                      (assoc-in [channel :last-activity] at)
                      ;; A DM is a room named after whoever is in it, and a
                      ;; nick is not a name that lasts. The DID is, so the
                      ;; record keeps it the first time the other end says
                      ;; anything — ours would name the wrong side.
                      (cond-> (and (dm? channel) did (not= from @form-nick))
                        (assoc-in [channel :peer-did] did))
                      ;; Reading a room *is* marking it read: a line that
                      ;; arrives while it is on screen moves the marker past
                      ;; itself. Everything else re-derives, so a line arriving
                      ;; in a room nobody is looking at costs a recount of that
                      ;; room and nothing more.
                      (update channel (if viewing? mark-read recount)))))))
     (remember-rooms! new-room?))))

(defn open-channel!
  "Show a buffer. A channel we are not in is joined on the way — a row can
  outlive the membership behind it (a disconnect drops every channel, the
  buffer stays), and opening one is a request to be in it."
  [name]
  (reset! current name)
  ;; On a wide window the conversation lives in the chats screen's second
  ;; pane, beside the list; :chat is the narrow window's way of showing it
  ;; instead of the list, and there is nothing there to trade it for.
  (reset! screen (if (wide?) :chats :chat))
  ;; A picker belongs to the message it was opened on; carrying it into another
  ;; buffer would offer to react to something that is no longer on screen.
  (reset! reacting nil)
  ;; And an edit belongs to a line in the buffer being left: carried across, the
  ;; next Send would rewrite a message nobody in this room can see.
  (when (and @editing (not= name (:channel @editing)))
    (reset! editing nil)
    (reset! draft ""))
  (swap! channels #(-> (ensure-channel % name)
                       (update name mark-read)
                       (assoc-in [name :accessed] (swap! access-tick inc))))
  (remember-rooms! true)
  ;; `joining?` as well as `joined?`: the JOIN echo takes a round trip, and a
  ;; second JOIN sent in the meantime is what makes the server replay nothing.
  (let [buffer (get @channels name)]
    (when (and @conn
               (str/starts-with? name "#")
               (not (:joined? buffer))
               (not (:joining? buffer)))
      (swap! channels #(assoc-in % [name :joining?] true))
      (irc/join! @conn name)))
  ;; Already in it, and nobody listed: the membership survived a restart the
  ;; NAMES that came with it did not.
  (when (:joined? (get @channels name))
    (request-names! name)))

(defn join-saved-rooms!
  "Ask to be in every channel `rooms.edn` says we are in.

  The server re-joins an authenticated user's channels itself, and gets it
  wrong in both directions — it forgets rooms and announces ones that are not
  ours. This is the half that answers the forgetting: the file says what we are
  in, so on arrival we say it too. A JOIN for a channel the server has already
  put us in is answered with the membership we already have, so asking twice
  costs nothing.

  DMs are not asked for. There is nothing to join in a conversation with a
  person; the buffer is the whole of it."
  []
  (when-let [conn @conn]
    (doseq [[name buffer] @channels
            :when (and (str/starts-with? name "#")
                       (not (:joined? buffer))
                       (not (:joining? buffer)))]
      (swap! channels #(assoc-in % [name :joining?] true))
      (irc/join! conn name))))

(defn leave-channel!
  "Leave a room and forget it: PART on the wire, gone from the list, gone from
  `rooms.edn`.

  The only way a room leaves the file. Everything else adds — the server
  announcing one, a message arriving in one — so without this the list is a
  thing that only grows, and the strictness above would have nothing to be
  strict about."
  [name]
  (when (and @conn (str/starts-with? name "#"))
    (irc/part! @conn name))
  (swap! channels dissoc name)
  (when (= name @current)
    (reset! current nil)
    (reset! screen :chats))
  (remember-rooms! true))

(def ^:private parse-reactions reactions/parse-tally)
(def ^:private with-reaction reactions/with-reaction)

(defn update-reaction!
  "One reaction folded into the buffer it belongs to. `frq.reactions` says what
  that means; this is the atom it means it to."
  [channel msgid emoji nick on?]
  (swap! channels reactions/update-reaction channel msgid emoji nick on?))

(defn edit-message!
  "Rewrite a message in place, and say so.

  `frq.edits` is the fold and what it answers; the atom and the picture links
  are this half's. A message keeps the id it was born with across every
  revision, which is what keeps its reactions, replies and pins attached to it
  — and `revision`, the msgid of the edit itself, is kept on it too, because a
  reply to an already-rewritten line names that one."
  ([channel msgid from text] (edit-message! channel msgid from text nil))
  ([channel msgid from text revision]
   (let [out (edits/apply-edit @channels channel msgid from text
                               {:decorate #(assoc % :images (media/image-urls text))
                                :revision revision})]
     (reset! channels (:channels out))
     (:result out))))

(defn- names-line [channel names]
  (swap! channels #(members/with-names (ensure-channel % channel) channel names)))

(defn- names-end! [channel]
  (swap! channels members/names-done channel))

(defn- add-user! [channel nick]
  (when (and channel nick)
    (swap! channels #(members/add-user (ensure-channel % channel) channel nick))))

(defn- remove-user! [channel nick]
  (swap! channels members/remove-user channel nick))

(defn- remove-user-everywhere! [nick]
  (swap! channels members/remove-everywhere nick))

(defn- rename-user! [old new]
  (swap! channels members/rename-user old new))

(defn- apply-mode! [channel modes args]
  (swap! channels members/with-mode channel modes args))

(defn member-list [channel]
  (members/member-list @channels channel))

(defn member-count [channel]
  (members/member-count @channels channel))

(defn request-names!
  "Ask who is in a channel we are already in. freeq re-joins an authenticated
  user's channels at registration, which happens without a JOIN reaching this
  client — and so without the NAMES that follows one."
  [channel]
  (when (and @conn channel (str/starts-with? channel "#")
             (empty? (get-in @channels [channel :users])))
    (irc/send-line! @conn (str "NAMES " channel))))

(declare join! join-call!)

;; --- calls -------------------------------------------------------------------
;; Signaling only. The audio and video themselves are `frq.av`'s, and behind it
;; libjoltmoq's; what happens here is that the server's broadcasts become state
;; the screens can read, and a press becomes a TAGMSG.

(defn apply-call-state!
  "A `+freeq.at/av-state` broadcast: fold it in, and say so in the buffer.

  The system line is worth the space — a call is the one thing that happens in
  a channel while nobody types, and without a line saying so the only trace of
  someone joining is a number quietly changing in a banner."
  [channel st]
  (av/apply-state! channel st)
  ;; And try to dial. The token may already be in hand — from this join, or
  ;; from the last time we were in this same session — in which case the
  ;; server's agreement that we are in the call is the last thing we were
  ;; waiting for. `try-start-media!` refuses if there is nothing to dial with
  ;; or a call is already up, so calling it on every state change is safe.
  (when (av/in-call? channel)
    (av/try-start-media! @form-host))
  (let [line (av/state-message st)]
    (when (seq line)
      (push-message! channel "*" line))))

(defn apply-call-error!
  "A `+freeq.at/av-error`. Most say the call failed; one says we lost a race.

  `start-collision` means our `av-start` and someone else's crossed and theirs
  won. The server names the winning session, so the answer is to join that one
  rather than to report an error for something the person asked for and can
  have — they wanted to be in a call in this room, and there is one."
  [tags code]
  (let [reason (or (irc/tag-value tags "+freeq.at/av-reason") code)
        session-id (irc/tag-value tags "+freeq.at/av-id")
        lc @av/local-call
        channel (:channel lc)]
    (if (and (= "start-collision" code) (seq session-id) channel
             (or (:awaiting-start? lc) (str/blank? (:session-id lc))))
      (do
        (push-message! channel "*" "Call already open — joining it instead")
        (av/stop-media!)
        (join-call! channel session-id))
      (do
        (when channel
          (push-message! channel "*" (str "Call error: " reason)))
        ;; Only tear down a call the error is actually about. A `join-failed`
        ;; naming someone else's session is not ours to act on.
        (when (and lc
                   (or (str/blank? (or session-id ""))
                       (str/blank? (:session-id lc))
                       (= session-id (:session-id lc))))
          (av/stop-media!))))))

;; Which channel's POLICY reply is outstanding, or nil. The server answers
;; POLICY with a run of NOTICEs addressed to our nick and naming no channel;
;; without this they land in the status banner one at a time, and the rules
;; the reader is being asked to accept are never readable.
;;
;; ponytail: the run ends at the first line that is not a NOTICE, so a PING
;; landing mid-answer truncates the rules. A reply-tag or a POLICY numeric
;; from the server would end it properly.
(defonce ^:private policy-asking (atom nil))

(defn ask-policy!
  "Ask the server what this channel's policy says, so the reader can read what
  they are being asked to accept.

  The answer comes back as plain NOTICEs to our nick, naming no channel — so
  the question is remembered here, and the lines that follow it are filed
  under the channel that asked."
  [ch]
  (swap! channels #(assoc-in (ensure-channel % ch) [ch :policy-text] []))
  (reset! policy-asking ch)
  (when-let [c @conn]
    (irc/send-line! c (str "POLICY " ch " RULES"))
    (irc/send-line! c (str "POLICY " ch " INFO"))))

(defn accept-policy!
  "Accept the channel's policy and go back in. The JOIN follows immediately:
  accepting is only ever done in order to be in the room, and the server takes
  the two in the order they are sent."
  [ch]
  (when-let [c @conn]
    (irc/send-line! c (str "POLICY " ch " ACCEPT"))
    (swap! channels #(-> (ensure-channel % ch)
                         (assoc-in [ch :policy-required?] false)
                         (assoc-in [ch :joining?] true)))
    (irc/join! c ch)))

(defn apply-msg!
  "Fold one parsed IRC message into the state."
  [msg]
  (let [{:keys [command params prefix]} msg
        from (irc/nick-of prefix)]
    (when (and @policy-asking (not= command "NOTICE"))
      (reset! policy-asking nil))
    (case command
      "001" (do (reset! status (if @session
                                  (str "Connected as " (:handle @session))
                                  (str "Connected as " @form-nick)))
                (reset! connecting? false)
                (reset! screen :chats)
                ;; This session decides once whether it is the one that
                ;; takes the room list over from the server. Before the flag
                ;; is set the file has never been told what we are in, so the
                ;; server's answer is adopted rather than argued with.
                (reset! adopting-rooms? (not @room-list-owned?))
                (when-not @room-list-owned?
                  (reset! room-list-owned? true)
                  (save-prefs!))
                ;; What the file says we are in, we ask to be in. The server
                ;; forgets rooms, and a room it has forgotten is one that
                ;; would otherwise quietly stop existing.
                (join-saved-rooms!)
                ;; Back where the reader left off. The list is still what a
                ;; connect lands on underneath, so Back from the reopened
                ;; channel goes to the chats rather than out of the app.
                (if-let [last-ch (first (channel-order))]
                  (open-channel! last-ch)
                  (join! auto-join)))
      "PRIVMSG" (let [[target text] params
                      ;; The server's clock when it offers one: a replayed
                      ;; backlog is hours or weeks old, and stamping it with
                      ;; the moment it arrived would say it all happened now.
                      at (or (clock/parse-time-tag (:tags msg)) (clock/now-ms))
                      tags (:tags msg)
                      ;; a DM addressed to us belongs in a buffer named for the
                      ;; sender, not for our own nick — except when the sender
                      ;; is us: `echo-message` sends our own DM back, and the
                      ;; buffer it belongs to is the one we sent it to.
                      buffer (cond
                               (str/starts-with? (or target "") "#") target
                               (= from @form-nick) target
                               :else from)
                      ;; What this message rewrites, when it is a rewrite. The
                      ;; server canonicalises the name to `+draft/edit`.
                      edit-of (irc/tag-value tags "+draft/edit")
                      ;; And what the server says about a line it has already
                      ;; collapsed: replay sends one row per message, carrying
                      ;; the current text and no `+draft/edit` to hint that it
                      ;; is not the original. This tag is the only trace.
                      replayed-edit? (= "1" (irc/tag-value tags "+freeq.at/edited"))]
                  (if edit-of
                    ;; A revision is not a new line: it replaces the one it
                    ;; names, under that line's own id rather than its own
                    ;; wire msgid. That msgid is not nothing, though — an
                    ;; answer to a line already rewritten names the revision,
                    ;; because the revision is the wording being answered — so
                    ;; it rides along on the message as a name it also
                    ;; answers to.
                    (when (= :absent (edit-message! buffer edit-of from text
                                                    (irc/tag-value tags "msgid")))
                      ;; The original is outside the backlog we hold, so show
                      ;; the current text rather than dropping what was said.
                      (push-message! buffer from text
                                     {:at at
                                      :did (:account msg)
                                      :id edit-of
                                      ;; Same two names, for the line we are
                                      ;; showing in place of the original.
                                      :edit-ids #{(irc/tag-value tags "msgid")}
                                      :edited? true
                                      :reply-to (or (irc/tag-value tags "+reply")
                                                    (irc/tag-value tags "+draft/reply"))}))
                    (push-message! buffer from text
                                   {:at at
                                    :did (:account msg)
                                    :id (irc/tag-value tags "msgid")
                                    :edited? replayed-edit?
                                    ;; The server canonicalises +draft/reply to
                                    ;; +reply; a client that sent the draft
                                    ;; name may still reach us before it does.
                                    :reply-to (or (irc/tag-value tags "+reply")
                                                  (irc/tag-value tags "+draft/reply"))
                                    :reactions (parse-reactions
                                                (irc/tag-value tags "+freeq.at/reactions"))})))
      ;; A message that is only tags. A reaction is the one this client reads:
      ;; `+react` puts an emoji on the message `+reply` names, and the server's
      ;; own `+freeq.at/unreact` takes it off again.
      "TAGMSG" (let [tags (:tags msg)
                     target (first params)
                     buffer (if (str/starts-with? (or target "") "#") target from)
                     msgid (or (irc/tag-value tags "+reply")
                               (irc/tag-value tags "+draft/reply"))
                     add (or (irc/tag-value tags "+react")
                             (irc/tag-value tags "+draft/react"))
                     remove-it (irc/tag-value tags "+freeq.at/unreact")
                     call-state (av/parse-state tags)
                     ;; The token is directed at our own nick rather than at
                     ;; the channel, so `buffer` is a DM key here and says
                     ;; nothing about which call it is for. The session id in
                     ;; the tag is what does.
                     token (irc/tag-value tags "+freeq.at/av-token")
                     call-error (irc/tag-value tags "+freeq.at/av-error")]
                 (cond
                   add (update-reaction! buffer msgid add from true)
                   remove-it (update-reaction! buffer msgid remove-it from false)
                   call-state (apply-call-state! buffer call-state)
                   token (av/apply-token! @form-host
                                          (irc/tag-value tags "+freeq.at/av-id")
                                          token)
                   call-error (apply-call-error! tags call-error)
                   :else nil))
      "JOIN" (let [ch (first params)]
               (if (= from @form-nick)
                 ;; Ours if the file says so — restored from rooms.edn, or
                 ;; asked for since. Anything else is the server putting us
                 ;; somewhere we did not ask to be, which it does: it
                 ;; announces memberships that are not real, and adding them
                 ;; is how a list nobody chose fills up with rooms.
                 ;;
                 ;; So we leave again, unless this is the session that is
                 ;; still adopting — on the first connect the file has not
                 ;; been told anything yet, and parting then would be leaving
                 ;; every room we are actually in.
                 (if (and (not (contains? @channels ch))
                          (not @adopting-rooms?))
                   (when @conn (irc/part! @conn ch))
                   (let [fresh? (empty? (get-in @channels [ch :messages]))]
                   (swap! channels #(-> (ensure-channel % ch)
                                        (assoc-in [ch :joined?] true)
                                        (assoc-in [ch :joining?] false)
                                        ;; In the room: whatever it was asking
                                        ;; for, it is not asking any more.
                                        (assoc-in [ch :policy-required?] false)))
                   ;; Only on the way in to an empty buffer. A reconnect joins
                   ;; every channel again, and saying so on top of the backlog
                   ;; already there is just a second line of noise.
                   (when fresh? (push-message! ch "*" (str "Joined " ch)))
                   ;; Adopted or asked for, it is ours now and the file should
                   ;; say so before the next connect judges it.
                   (remember-rooms! true)))
                 ;; Somebody else arriving in a room we do not hold is not a
                 ;; reason to start holding it: `add-user!` and `push-message!`
                 ;; both build the buffer they are given, so either one would
                 ;; put the refused room back in the list.
                 (when (contains? @channels ch)
                   (add-user! ch from)
                   (when-not @hide-join-part?
                     (push-message! ch "*" (str from " joined"))))))
      ;; NAMES, a line at a time. The channel is the parameter that names one:
      ;; the reply is `<us> <symbol> <channel> :<names>`, and a server that
      ;; leaves the symbol out shifts everything before the list along by one.
      "353" (let [ch (first (filter #(str/starts-with? (or % "") "#") params))]
              (when ch (names-line ch (last params))))
      ;; End of NAMES. A plain JOIN is replayed history before this arrives, so
      ;; a channel that reaches here with nothing in it was restored rather
      ;; than joined — freeq re-joins an authenticated user's channels at
      ;; registration and leaves the backlog for the client to ask for.
      "366" (let [ch (second params)
                  said (remove :system? (get-in @channels [ch :messages]))]
              (names-end! ch)
              (when (and ch @conn (empty? said))
                (irc/send-line! @conn
                                (str "CHATHISTORY LATEST " ch " * " history-limit))))

      ;; `assoc-in` on a channel that is not there does not fail, it invents
      ;; one — a buffer with a `:joined?` and nothing else, no name and no
      ;; unread, which the room list then tries to draw. That is not
      ;; hypothetical now: refusing a room the file does not claim sends PART,
      ;; and the server echoes it straight back at us. A membership changing in
      ;; a room we do not hold is nothing to record.
      "PART" (let [ch (first params)]
               (if (= from @form-nick)
                 (swap! channels #(if (contains? % ch)
                                    (-> % (assoc-in [ch :joined?] false)
                                          (assoc-in [ch :joining?] false)
                                          (assoc-in [ch :users] {}))
                                    %))
                 (when (contains? @channels ch)
                   (remove-user! ch from)
                   (when-not @hide-join-part?
                     (push-message! ch "*" (str from " left"))))))
      "KICK" (let [[ch who] params]
               (if (= who @form-nick)
                 (swap! channels #(if (contains? % ch)
                                    (-> % (assoc-in [ch :joined?] false)
                                          (assoc-in [ch :joining?] false)
                                          (assoc-in [ch :users] {}))
                                    %))
                 (remove-user! ch who))
               (when (contains? @channels ch)
                 (push-message! ch "*" (str who " was kicked by " from))))
      ;; A QUIT and a NICK name no channel, so both are folded into every
      ;; buffer the person was listed in — and said out loud only where they
      ;; were, which is what keeps a stranger's rename out of a quiet room.
      "QUIT" (let [rooms (keep (fn [[k v]] (when (get (:users v) from) k)) @channels)]
               (when-not @hide-join-part?
                 (doseq [ch rooms]
                   (push-message! ch "*" (str from " quit"))))
               (remove-user-everywhere! from))
      "NICK" (let [new-nick (last params)
                   rooms (keep (fn [[k v]] (when (get (:users v) from) k)) @channels)]
               (when (= from @form-nick) (reset! form-nick new-nick))
               (doseq [ch rooms]
                 (push-message! ch "*" (str from " is now " new-nick)))
               (rename-user! from new-nick))
      "MODE" (let [[target modes & args] params]
               (when (str/starts-with? (or target "") "#")
                 (apply-mode! target modes args)))
      "NOTICE"
      (let [text (str/trimr (or (last params) ""))]
        (cond
          ;; The server's half of freeq that is REST rather than IRC: sent
          ;; once, straight after SASL succeeds, and the only way to get one.
          ;; Kept rather than shown — see `frq.replies`, which spends it
          ;; asking what a msgid was.
          (str/starts-with? text "API-BEARER ")
          (reset! cells/api-bearer (str/trim (subs text (count "API-BEARER "))))

          @policy-asking
          (swap! channels #(update-in (ensure-channel % @policy-asking)
                                      [@policy-asking :policy-text]
                                      (fnil conj []) text))

          :else (reset! status (or (last params) @status))))
      ("372" "375" "376" "002" "003" "004")
      (reset! status (or (last params) @status))
      ;; 473 invite-only, 474 banned, 475 keyed, 477 needs registration,
      ;; 471 full, 403 no such channel. The channel is params[1]; clearing its
      ;; flags is what lets a later attempt send a JOIN at all.
      ("473" "474" "475" "477" "403" "471")
      (let [ch (second params)
            why (last params)]
        (when ch
          (swap! channels #(-> (ensure-channel % ch)
                               (assoc-in [ch :joined?] false)
                               (assoc-in [ch :joining?] false)))
          (push-message! ch "*" (str "Could not join " ch " — " why))
          ;; The one refusal the reader can answer themselves: the room is not
          ;; shut to them, it is waiting on them to say yes to something. The
          ;; flag is what puts the Accept button in the channel, and the rules
          ;; are asked for so it is not a yes to an unread page.
          (when (str/includes? (str/lower-case (or why "")) "policy")
            (swap! channels #(assoc-in % [ch :policy-required?] true))
            (ask-policy! ch)))
        ;; Deliberately not the global banner: it outlives the screen it was
        ;; about, and the reason is in the channel's own buffer where it
        ;; belongs. The banner is for what stops the whole app — a failed
        ;; connection or a refused sign-in.
        (when-not ch (reset! error (str "Cannot join: " why))))
      ;; What the server refused and why, in the reader's words. An edit or a
      ;; reaction it will not take is otherwise silent: the line on screen
      ;; simply never changes, which reads as the app having lost it.
      "FAIL" (let [[what _code] params]
               (reset! error (str (or what "Request") " refused — "
                                  (or (last params) "no reason given"))))
      "903" (reset! status (str "Signed in as " (:handle @session)))
      ("904" "905" "906") (do (reset! session nil)
                              ;; The broker token may still be good — but a
                              ;; refusal is as likely to mean it is not, and a
                              ;; stale one would fail the same way every time,
                              ;; including across restarts if it were kept.
                              (reset! broker-token nil)
                              (store/clear-session!)
                              (reset! error (str "Bluesky sign-in refused: "
                                                 (or (last params) "no reason given"))))
      ;; The signing key belonged to that connection: the server forgets it
      ;; when the session ends, and signing with it afterwards would be
      ;; signing with a key nobody can check.
      "*DISCONNECTED*" (do (msgsig/forget!)
                           ;; The bearer belongs to the session that is over,
                           ;; and what was asked under it deserves asking
                           ;; again under the next one.
                           (reset! cells/api-bearer nil)
                           (replies/forget-asks!)
                           (reset! conn nil)
                           (reset! connecting? false)
                           (swap! channels
                                  #(reduce-kv (fn [m k v]
                                                (assoc m k (assoc v :joined? false :joining? false :users {})))
                                              {} %))
                           (reset! status "Disconnected"))
      "*ERROR*" (do (reset! error (first params))
                    (reset! connecting? false))
      nil)))

(def plain-port 6667)

(defn- describe
  "What went wrong, in words. A jolt condition prints as #object[:object], so
  the message and the ex-data are what has to be dug out by hand."
  [e]
  (let [msg (ex-message e)]
    (if (seq msg)
      msg
      ;; A raw host condition prints as #object[:object] and says nothing, so
      ;; its type is the only thing left worth showing.
      (str (type e) ": " (str e)))))

(defn- dial! [host port nick tls? sess]
  ;; stderr is the only console on Android — this line lands in logcat.
  (binding [*out* *err*]
    (println "frq: dialing" host port (if tls? "tls" "plain")))
  (reset! conn (irc/connect! host port nick apply-msg! tls? sess)))

(defn- connect-blocking!
  "Sign in if asked to, then dial. Blocking throughout — a browser handoff can
  take a minute, and the TLS handshake is not instant either."
  []
  (reset! error nil)
  (reset! connecting? true)
  (reset! status (str "Connecting to " @form-host ":" @form-port "…"))
  (let [host @form-host
        port (parse-long (str/trim @form-port))
        mode @auth-mode
        sess (case mode
               ;; OAuth: the browser does the talking, we wait on loopback. A
               ;; broker token in hand skips the browser entirely.
               :bluesky
               (let [handle (str/trim @form-handle)
                     browser! (fn []
                                (reset! status "Opening your browser to sign in…")
                                (oauth/await-callback!
                                 oauth/default-broker handle
                                 (fn [url]
                                   (reset! login-url url)
                                   (oauth/open-browser! url)
                                   (reset! status "Waiting for the browser…"))))
                     tokens (if-let [bt @broker-token]
                              ;; A saved token that the broker no longer honours
                              ;; is worth exactly one attempt: drop it and go
                              ;; through the browser, rather than failing the
                              ;; same way on every future Connect.
                              (try (reset! status "Resuming your session…")
                                   (oauth/refresh-session oauth/default-broker bt)
                                   (catch Exception _
                                     (reset! broker-token nil)
                                     (store/clear-session!)
                                     (reset! status "Saved session expired — signing in again…")
                                     (browser!)))
                              (browser!))
                     s (assoc tokens :kind :web-token)]
                 (reset! login-url nil)
                 (reset! broker-token (:broker-token tokens))
                 ;; Saved on every sign-in, not only the first: /session can
                 ;; hand back a rotated broker token, and the old one may stop
                 ;; working the moment it does.
                 (store/save-session! tokens)
                 (reset! session s)
                 (when (seq (:handle tokens)) (reset! form-handle (:handle tokens)))
                 s)

               :app-password
               (do (reset! status (str "Signing in as " (str/trim @form-handle) "…"))
                   (let [s (assoc (atproto/create-session (str/trim @form-handle)
                                                          @form-app-password)
                                  :kind :pds-session)]
                     (reset! session s)
                     ;; The password did its work at the PDS; do not keep it.
                     (reset! form-app-password "")
                     s))

               nil)
        ;; An authenticated connection still needs a nick — the DID is the
        ;; identity, the nick is only what the channel calls you.
        nick (if sess
               (or (:nick sess)
                   (-> (or (:handle sess) "") (str/split #"\\.") first)
                   (str/trim @form-nick))
               (str/trim @form-nick))]
    (when sess (reset! form-nick nick))
    (try
      (dial! host port nick @form-tls? sess)
      (catch Exception e
        (binding [*out* *err*] (println "frq: dial failed:" (describe e)))
        (if @form-tls?
          (do (reset! status (str "TLS unavailable — trying " host ":" plain-port "…"))
              (try
                (dial! host plain-port nick false sess)
                (reset! form-tls? false)
                (reset! form-port (str plain-port))
                (catch Exception e2
                  (binding [*out* *err*] (println "frq: plain dial failed:" (describe e2)))
                  (reset! connecting? false)
                  (reset! conn nil)
                  (reset! status "Not connected")
                  (reset! error (str "Could not connect: " (describe e2))))))
          (do (reset! connecting? false)
              (reset! conn nil)
              (reset! status "Not connected")
              (reset! error (str "Could not connect: " (describe e)))))))))

(defn connect!
  "Start connecting. The work happens on another thread: the OAuth wait sits on
  a loopback accept until the browser comes back, and the UI has frames to
  paint in the meantime.

  A second call while one is in flight is ignored. Dialling twice does not just
  waste a socket: the server treats the second session as a reconnect of the
  first, and a reconnect is not replayed the channel history a fresh join gets,
  so the second connection — the one the UI ends up holding — shows an empty
  channel."
  []
  (when-not (or @connecting? @conn)
    (reset! error nil)
    (reset! connecting? true)
    (future
      (try (connect-blocking!)
           (catch Exception e
             (reset! connecting? false)
             (reset! conn nil)
             (reset! status "Not connected")
             (reset! error (str "Could not connect: " (describe e))))))))

(defn restore-session!
  "Pick up a saved sign-in at startup. Only the durable broker token comes
  back; the connection still mints a fresh web-token from it."
  []
  (when-let [saved (store/load-session)]
    (reset! broker-token (:broker-token saved))
    (when (seq (:handle saved)) (reset! form-handle (:handle saved)))
    (when (seq (:nick saved)) (reset! form-nick (:nick saved)))
    (reset! auth-mode :bluesky)
    (reset! status (str "Signed in as " (:handle saved) " — Connect to resume"))
    saved))

(defn forget-session!
  "Drop the saved sign-in, on disk and in memory."
  []
  (store/clear-session!)
  (reset! broker-token nil)
  (reset! cells/api-bearer nil)
  (replies/forget-asks!)
  (reset! session nil)
  (reset! auth-mode :guest)
  (reset! status "Not connected"))

(defn disconnect! []
  (when-let [c @conn] (irc/close! c))
  (reset! conn nil)
  (reset! session nil)
  ;; The buffers survive, the memberships do not — leaving `joined?` set would
  ;; have the next Open show a channel nobody is in.
  (swap! channels #(reduce-kv (fn [m k v]
                                (assoc m k (assoc v :joined? false :joining? false :users {})))
                              {} %))
  (reset! status "Not connected")
  (reset! screen :connect))

(defn open-dm!
  "Open a conversation with one person. There is nothing to join — a DM buffer
  is a place to type at somebody, and it exists as soon as it is asked for.

  Our own nick is not one of them: a buffer talking to yourself would take the
  place in the list of one that could answer."
  [nick]
  (let [nick (str/trim (or nick ""))]
    (when (and (seq nick) (not= nick @form-nick))
      (open-channel! nick))))

(defn join! [name]
  ;; Deliberately not clearing `error` here: joining is what follows a
  ;; successful registration, and a SASL refusal that arrived moments earlier
  ;; is the one thing the user most needs to still be on screen.
  ;;
  ;; `@nick` opens a DM instead. One box for both: what the reader wants is to
  ;; be somewhere, and the sigil says where — the same way it does on the wire.
  (let [name (str/trim (or name ""))]
    (if (str/starts-with? name "@")
      (open-dm! (subs name 1))
      (let [ch (normalize-channel name)]
        (when (seq ch)
          (open-channel! ch))))))

;; ------------------------------------------------------------------ pasting

(def attachment cells/attachment)

;; Each paste gets a file of its own rather than overwriting the last: the
;; preview is painted from the file, and an upload may still be reading it.
(defonce ^:private paste-count (atom 0))

(defn- paste-path []
  (let [n (swap! paste-count inc)]
    (str (media/cache-dir) "/outgoing/paste-" n ".png")))

(defn- discard-file!
  "Drop a paste's copy on disk. Nothing else keeps it: the picture that matters
  after sending is the one the server serves back, which the media cache
  fetches like any other."
  [path]
  (when path (try (host/delete-file! path) (catch Exception _ nil))))

(defn clear-attachment!
  "Drop the pasted picture without sending it."
  []
  (when-let [a @attachment]
    (reset! attachment nil)
    (discard-file! (:path a))))

(defn- attach!
  "Hold the picture already written to `path` — a copy of ours under
  `outgoing/` — against the next line, and start its upload.

  The upload runs off the UI thread and starts at once rather than at send, so
  by the time a line is written the picture is usually already up. A failure
  lands in `error` like any other, and takes the attachment with it — there is
  nothing to send and nothing to show.

  `filename` is what the server files it under; it says which gesture the
  picture came in by, and nothing else depends on it."
  [path filename]
  (let [did (:did @session)
        host-name @form-host
        channel @current]
    (reset! error nil)
    (clear-attachment!)
    (reset! attachment {:path path :status :uploading})
    (future
      (try
        (let [url (upload/upload! host-name did channel path filename)]
          ;; Only if this is still the picture on screen: a reader who attached
          ;; another, or cleared it, has said what they want, and an upload
          ;; landing afterwards does not get to undo that.
          (swap! attachment #(if (= (:path %) path)
                               (assoc % :url url :status :ready)
                               %))
          (when-not (= (:path @attachment) path) (discard-file! path)))
        (catch Exception e
          (swap! attachment #(if (= (:path %) path) nil %))
          (discard-file! path)
          (reset! error (or (ex-message e) (str e))))))))

(defn paste-image!
  "Take the picture on the clipboard and hold it against the next line.

  IRC has nowhere to put an image, so a link is the whole of what sending one
  means — but that is a fact about the wire, not something the reader should
  have to type around. The picture is attached: shown under the draft while
  they write whatever they are sending it with, and turned into a link only on
  the way out."
  []
  (let [path (paste-path)]
    (host/mkdirs! (str (media/cache-dir) "/outgoing"))
    (if-not (platform/clipboard-image-png! path)
      ;; Android has no clipboard of pictures to read at all, which is the
      ;; other half of why the picker below exists.
      (reset! error "No picture on the clipboard.")
      (attach! path "paste.png"))))

;; ------------------------------------------------------------------ picking

(def image-picker cells/image-picker)

(defn- readable-dir? [path]
  (try (and (host/file-exists? path) (host/directory? path))
       (catch Exception _ false)))

(defn picker-roots
  "The places worth opening the picker on, on whichever platform this is.

  Only the ones that are actually there: a phone has no ~/Pictures and a
  desktop no /sdcard, and a list of directories that are not there is a list of
  dead ends. On Android everything outside the app's own storage is behind a
  runtime permission this activity has no code to ask for, so what survives
  this filter there is usually the app's own files — which is the honest
  answer, not a bug to paper over."
  []
  (let [home (or (host/getenv "HOME") "")
        under (fn [base] (when (seq base)
                           (map #(str base "/" %)
                                ["Pictures" "Downloads" "Download" "DCIM"])))]
    (vec (distinct (filter readable-dir?
                           (concat (under home)
                                   (under "/sdcard")
                                   (under "/storage/emulated/0")
                                   [(media/cache-dir) home]))))))

(defn- png? [name]
  (str/ends-with? (str/lower-case (str name)) ".png"))

(defn picker-entries
  "What `dir` holds, as `{:dirs [...] :files [...]}` of full paths.

  PNG only, for the same reason the media cache reads PNG only: it is what the
  tree backend paints and what the upload sends. An unreadable directory —
  which on Android is most of them — answers empty rather than throwing.

  Hidden entries are left out: nothing a reader means to send lives in one, and
  a home directory is unusable as a list with them in it."
  [dir]
  (let [names (try (sort (host/list-dir dir)) (catch Exception _ nil))
        keep (remove #(str/starts-with? (str %) ".") names)
        path (fn [n] (str dir "/" n))]
    {:dirs (vec (filter readable-dir? (map path keep)))
     :files (vec (map path (filter png? keep)))}))

(defn parent-dir
  "The directory above `dir`, or nil at the top."
  [dir]
  (let [up (str/join "/" (butlast (str/split (str dir) #"/")))]
    (when (and (seq up) (not= up dir) (readable-dir? up)) up)))

;; ------------------------------------------- the platform's own chooser

;; Polling, because a chooser is another app's screen: it takes the reader away
;; and gives nothing back through a handler here. `choosing` is what the poll
;; runs on, and the count is what ends it — a reader who backs out without
;; choosing tells us nothing at all, so the alternative is a poll that outlives
;; the app's interest in the answer.
(defonce ^:private choosing (atom nil))

(def ^:private choose-poll-ms 300)

(def ^:private choose-poll-limit
  "Five minutes of asking. Long enough for someone who wandered off mid-choice,
  short enough that a cancelled chooser is not still being polled for at
  bedtime."
  1000)

(defn- take-chosen!
  "Attach the picture the chooser has written, if it has written one yet."
  []
  (let [path (paste-path)]
    (host/mkdirs! (str (media/cache-dir) "/outgoing"))
    (when (platform/picked-image! path)
      (reset! choosing nil)
      (attach! path "picture.png")
      true)))

(defn- poll-chosen! []
  (when-let [left @choosing]
    (when-not (take-chosen!)
      (if (pos? left)
        (do (reset! choosing (dec left))
            (platform/after! choose-poll-ms poll-chosen!))
        (reset! choosing nil)))))

(defn choose-image!
  "Open the platform's own picture chooser, where there is one; true when it
  opened.

  Preferred to browsing on a phone, and not only for the taste of it: what the
  chooser hands back is a grant for the one picture the reader chose, so the
  app needs no permission over their pictures at all — and without such a
  permission, browsing finds almost nothing to show. False where there is no
  chooser, which is every desktop, and there browsing is the answer."
  []
  (when (platform/pick-image!)
    (reset! error nil)
    (reset! choosing choose-poll-limit)
    (platform/after! choose-poll-ms poll-chosen!)
    true))

(defn open-image-picker!
  "Ask for a picture, whichever way this platform has of choosing one.

  The platform's own chooser where there is one — it needs no permission and
  knows where the reader's pictures actually are — and otherwise this app's
  own browsing screen, which is what a desktop gets."
  []
  (when-not (choose-image!)
    (reset! error nil)
    (reset! image-picker (or (first (picker-roots)) "/"))))

(defn close-image-picker! [] (reset! image-picker nil))

(defn browse! [dir] (when (readable-dir? dir) (reset! image-picker dir)))

(defn- copy-file!
  "Copy `from` to `to`, byte for byte."
  [from to]
  (let [in (java.io.FileInputStream. from)]
    (try
      (let [out (java.io.FileOutputStream. to)]
        (try (.write out (.readAllBytes in))
             (finally (.close out))))
      (finally (try (.close in) (catch Exception _ nil))))))

(defn pick-image!
  "Attach the picture at `path` and close the picker.

  Copied into `outgoing/` first rather than attached where it lies: the send
  drops the attachment's file when it is done with it, and what it drops has to
  be ours — not the reader's own picture, sitting in their pictures folder."
  [path]
  (let [copy (paste-path)]
    (try
      (host/mkdirs! (str (media/cache-dir) "/outgoing"))
      (copy-file! path copy)
      (close-image-picker!)
      (attach! copy (or (last (str/split (str path) #"/")) "picture.png"))
      (catch Exception e
        (discard-file! copy)
        (reset! error (str "Could not read that picture: " (or (ex-message e) e)))))))

(defn- dm-peer-did
  "Who this DM is with. `frq.reactions` reads it out of the buffer."
  [channel]
  (reactions/peer-did @channels channel @form-nick))

(defn mine?
  "Whether we are the one who said this. Nick against nick, which is what the
  server itself falls back to for an account with no DID — and an edit it would
  refuse is one not worth offering."
  [m]
  (rooms/mine? m @form-nick))

(defn start-edit!
  "Put a message back in the box to be rewritten.

  The old text is the starting point rather than an empty line: an edit is
  usually a word, and retyping the sentence around it is not what was asked
  for. Whatever was half-typed is dropped — a draft and an edit are two things
  to say, and the box holds one."
  [channel m]
  (when (and (:id m) (mine? m))
    (reset! replying-to nil)
    (reset! editing {:channel channel :id (:id m)})
    (reset! draft (or (:text m) ""))))

(defn cancel-edit!
  "Leave the message as it was said. The box empties with it: what is in it is
  a copy of the line on screen, and leaving that behind would look like a draft
  the reader wrote."
  []
  (reset! editing nil)
  (reset! draft ""))

(defn send-draft!
  "Send the draft, with whatever picture is attached to it.

  The picture becomes its link, at the end of the line: what goes on the wire
  is the text the reader wrote and a URL after it, which is what every other
  client in the channel knows how to show. A line that is only a picture is
  only the link.

  A picture still on its way up holds the send rather than losing it: the line
  is left in the box, said so, and the reader presses send again a moment
  later. Sending the text without its picture would be the one outcome nobody
  asked for.

  A draft with a break in it is several messages. There is no newline on the
  wire — a PRIVMSG is one line and a line ends where the protocol says it does
  — so the box that lets a reader write a paragraph has to be the thing that
  takes it apart again: one message a line, in order, blank lines dropped. Only
  the last one carries the picture, and only the first one answers the message
  being replied to; the rest are the same thought continuing."
  []
  (let [lines (->> (str/split-lines @draft)
                   (map str/trim)
                   (remove str/blank?))
        ;; What the branches below that are about one line read: a command and
        ;; a rewrite are single-line things whatever the box holds.
        text (str/join " " lines)
        target @current
        reply-to @replying-to
        edit @editing
        {:keys [url status path] :as att} @attachment]
    (cond
      (not target) nil
      ;; A line beginning with "/" is said to the server, not to the room:
      ;; POLICY, MODE, whatever the server asks for by name. Without it a
      ;; channel that answers a JOIN with "use POLICY <channel> ACCEPT" is one
      ;; the reader can see the instructions for and has no way to follow.
      ;; "//" is how you say a line that really does start with a slash.
      (and (str/starts-with? text "/") (not (str/starts-with? text "//")))
      (if-let [c @conn]
        (let [line (str/trim (subs text 1))]
          (when (seq line)
            (irc/send-line! c line)
            (push-message! target "*" (str "> " line)))
          (reset! draft ""))
        (reset! error "Not connected."))
      (= :uploading status) (reset! error "The picture is still uploading.")
      ;; A rewrite replaces what was said, and what was said is a line of text:
      ;; there is no wire form for adding a picture to a message already sent,
      ;; so the attachment is held back rather than silently dropped.
      (and edit att) (reset! error "Finish the edit before sending a picture.")
      (and edit (str/blank? text)) nil
      edit
      (do (when-let [c @conn]
            (irc/edit! c (:channel edit) (:id edit) text
                       (dm-peer-did (:channel edit))))
          ;; Same reason as a new message: the server's echo is the copy that
          ;; every other client sees, and folding this one in as well would
          ;; rewrite the line twice. Without echo-message nothing comes back,
          ;; so the rewrite has to be applied here or it never shows.
          (when-not (some-> @conn (irc/cap-acked? "echo-message"))
            (edit-message! (:channel edit) (:id edit) @form-nick text))
          (reset! editing nil)
          (reset! draft ""))
      (and (str/blank? text) (not url)) nil
      :else
      (let [lines (map #(if (str/starts-with? % "//") (subs % 1) %) lines)
            ;; The picture rides the last line, so a message that is only a
            ;; picture is the link on its own.
            lines (if (seq lines) (vec lines) [""])
            last-i (dec (count lines))
            lines (map-indexed (fn [i line]
                                 (str/trim (str line (when (and url (= i last-i))
                                                       (str " " url)))))
                               lines)]
        ;; Saying something is a way of asking to see it.
        (jump-to-present!)
        (doseq [[i line] (map-indexed vector lines)]
          (when-let [c @conn]
            (irc/privmsg! c target line (when (zero? i) (:id reply-to))))
          ;; Only when the server will not send the line back itself. Its copy
          ;; carries the msgid, and a message with no id is one nobody can react
          ;; or reply to; echoing locally as well would put the line up twice.
          (when-not (some-> @conn (irc/cap-acked? "echo-message"))
            (push-message! target @form-nick line
                           {:reply-to (when (zero? i) (:id reply-to))})))
        (reset! replying-to nil)
        (reset! draft "")
        (when att
          (reset! attachment nil)
          ;; The picture on screen from here on is the one fetched back from
          ;; the link, like everyone else's.
          (discard-file! path))))))


(defn open-picker!
  "Choose an emoji for this message. Opening it fresh — no leftover search from
  the last time, which would be a screen of somebody else's question."
  [channel m]
  (when (:id m)
    (reset! emoji-search "")
    (reset! emoji-group nil)
    (reset! reacting {:channel channel :id (:id m)})))

(defn close-picker! [] (reset! reacting nil))

(def picker-emoji
  "Moved to `frq.reactions`: it is the cells and the catalog, both of which
  are shared, and the phone shows the same picker."
  reactions/picker-emoji)

(defn my-reaction?
  "Whether this nick is already on that emoji — which is what makes a second
  click take it off rather than send the same reaction twice."
  [m emoji]
  (reactions/mine? m emoji @form-nick))

(def reaction-hover cells/reaction-hover)

(defn hover-reaction!
  "The pointer has come to rest on a pill."
  [msgid emoji]
  (reset! reaction-hover {:id msgid :emoji emoji}))

(defn unhover-reaction!
  "The pointer has left that pill. Guarded by which one is being left, so
  crossing straight from one pill to the next — both edges in a frame — cannot
  take down the card that has just been raised."
  [msgid emoji]
  (swap! reaction-hover #(when-not (= {:id msgid :emoji emoji} %) %)))

(defn hovering-reaction?
  "Whether this is the pill the card belongs to."
  [msgid emoji]
  (= {:id msgid :emoji emoji} @reaction-hover))

(defn toggle-reaction!
  "Put my emoji on a message, or take it off if it is already mine.

  Applied here as well as sent: the server relays a TAGMSG to everyone in the
  channel *except* the client that sent it, so without this the pill would only
  appear once someone else reacted too."
  [channel m emoji]
  (when-let [msgid (:id m)]
    (let [on? (not (my-reaction? m emoji))
          ;; Who the DM is with, for the signature: freeq names a DM by both
          ;; DIDs rather than by a nick, and nothing else in a buffer says
          ;; which account the other side is. nil in a channel, which is named
          ;; by itself.
          peer (dm-peer-did channel)]
      (when-let [c @conn]
        (if on?
          (irc/react! c channel msgid emoji peer)
          (irc/unreact! c channel msgid emoji peer)))
      (update-reaction! channel msgid emoji @form-nick on?))))

(defn start-call!
  "Open a call on this channel.

  Optimistic: the controls appear on the press. What comes back settles it —
  an `av-state` says the room has a call, an `av-token` starts the media, and
  a `start-collision` means someone beat us to it and we join theirs instead."
  [channel]
  (when-let [c @conn]
    (let [nick (or (:nick @session) @form-nick)
          instance (av/begin! {:channel channel
                               :nick nick
                               :muted? false
                               :speaker-muted? false
                               ;; Audio first, always. A call that opened with
                               ;; the camera on would be a call that showed
                               ;; someone's room before they had agreed to.
                               :camera? false})]
      (irc/tagmsg! c channel (av/start-tags instance nil)))))

(defn join-call!
  "Join the call already open on this channel."
  [channel session-id]
  (when-let [c @conn]
    (let [nick (or (:nick @session) @form-nick)
          instance (av/begin! {:channel channel
                               :session-id session-id
                               :nick nick
                               :muted? false
                               :speaker-muted? false
                               :camera? false})]
      (irc/tagmsg! c channel (av/join-tags session-id instance)))))

(defn announce-leave!
  "Tell the room this device is out of a call it did not choose to leave.

  freeq counts a participant until an `av-leave` says otherwise, so a media
  plane that fails silently leaves a ghost behind — and the next Join adds
  another beside it. Registered with `frq.av` at startup, because that
  namespace has no connection to send on."
  [{:keys [channel session-id instance]}]
  (when (and @conn (seq (or session-id "")))
    (irc/tagmsg! @conn channel (av/leave-tags session-id instance))))

(defn leave-call!
  "Leave the call, telling the room and the SFU both.

  The media plane goes down first and on its own account: the person pressed
  leave, so the microphone should be shut whether or not the TAGMSG gets out."
  []
  (when-let [{:keys [channel session-id instance]} @av/local-call]
    (av/stop-media!)
    (when-let [c @conn]
      (when (seq session-id)
        (irc/tagmsg! c channel (av/leave-tags session-id instance))))))

(def channel-list rooms/channel-list)

(defn channel-order
  "The buffer names, most recently opened first — what gets written to disk.
  Buffers never opened are left out: a DM that arrived once and was never read
  is not a place this client has been, and neither is a channel someone
  mentioned. One that was opened is, whether it is a room or a person."
  []
  (->> (vals @channels)
       (filter #(pos? (:accessed % 0)))
       (sort-by #(- (:accessed % 0)))
       (mapv :name)))

(def room-records rooms/room-records)

(def restore-channels! rooms/restore-channels!)

(defn message-by-id
  "The message a reply points at, if this buffer still holds it.

  By any name it has had — a `:local-id` for a line the server never named,
  and the msgid of any revision of it. `frq.rooms/answers-to?` is that rule,
  shared so both halves resolve a reply the same way."
  [channel id]
  (rooms/message-by-id @channels channel id))

(defn react-from-picker!
  "Put the chosen emoji on the message the picker was opened for, and close it.
  One choice and back to the conversation: a picker left open would be asking a
  question that has been answered."
  [emoji]
  (when-let [{:keys [channel id]} @reacting]
    (when-let [m (message-by-id channel id)]
      (toggle-reaction! channel m emoji))
    (close-picker!)))


(def jump-to cells/jump-to)

(def highlight cells/highlight)


(def overview-limit rooms/overview-limit)

(def recent-everywhere rooms/recent-everywhere)

(def last-preview rooms/last-preview)

;; What the shared screens call. Installed here rather than in an entry point
;; because these are this namespace's own reducers, and the screens that call
;; them are no longer in a position to name them.
(actions/install!
 {:connect! connect!
  :disconnect! disconnect!
  :forget-session! forget-session!
  :connected? connected?
  :join! join!
  :open-channel! open-channel!
  :leave-channel! leave-channel!
  :toggle-hide-join-part! toggle-hide-join-part!
  :browse! browse!
  :close-image-picker! close-image-picker!
  :pick-image! pick-image!
  :parent-dir parent-dir
  :picker-entries picker-entries
  :picker-roots picker-roots
  :media-tick (fn [] @media-tick)
  :avatar-ready (fn [actor] (avatars/path-when-ready actor))
  :send-draft! send-draft!
  :cancel-edit! cancel-edit!
  :cancel-reply! cancel-reply!
  :clear-attachment! clear-attachment!
  :open-image-picker! open-image-picker!
  :paste-image! paste-image!
  :jump-to-present! jump-to-present!
  :scrolled! scrolled!
  :toggle-users! toggle-users!
  :toggle-chat-list! toggle-chat-list!
  :toggle-overview! toggle-overview!
  :wide? wide?
  :member-count member-count
  :start-call! start-call!
  :in-call? av/in-call?
  :call-in av/call-in
  :call-available? av/available?
  :desktop? platform/desktop?
  :quit! platform/quit!
  :avatar-path nil
  :image-path nil
  :local-call (fn [] @av/local-call)
  :local-feed (fn [] av/local-feed)
  :media-error (fn [] @av/media-error)
  :tiles av/tiles
  :tile-rows av/tile-rows
  :set-muted! av/set-muted!
  :set-speaker-muted! av/set-speaker-muted!
  :set-camera! av/set-camera!
  :after! platform/after!
  :open-url! platform/open-url!
  :accept-policy! accept-policy!
  :close-picker! close-picker!
  :hover-reaction! hover-reaction!
  :join-call! join-call!
  :leave-call! leave-call!
  :leaving-for-overview! leaving-for-overview!
  :member-list member-list
  :message-by-id message-by-id
  :mine? mine?
  :my-reaction? my-reaction?
  :open-dm! open-dm!
  :open-picker! open-picker!
  :overview-back! overview-back!
  :picker-emoji picker-emoji
  :react-from-picker! react-from-picker!
  :recent-everywhere recent-everywhere
  :reply-to! reply-to!
  ;; A reply chip that found nothing asks what that msgid was; the repaint is
  ;; the same tick a picture or a face arriving uses, because it is the same
  ;; shape of answer — something a row read, arriving after the row was drawn.
  :resolve-reply! (fn [channel id]
                    (replies/resolve! channel id #(swap! media-tick inc)))
  :start-edit! start-edit!
  :toggle-reaction! toggle-reaction!
  :unhover-reaction! unhover-reaction!})
