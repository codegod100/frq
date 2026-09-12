(ns frq.rooms
  "What the conversation list is, derived from the cells it is held in.

  Pure, and so shared: `channel-list` is a filter and a sort over
  `frq.cells/channels` and the search box, `dm?` is a question about a name,
  `last-preview` reads the last message of a buffer, `recent-everywhere` is
  the overview strip's list of what is happening in every other room. `frq.state`
  re-defs them all, so the thousand lines below them did not move."
  (:require [clojure.string :as str]
            [frq.cells :as cells]
            [frq.clock :as clock]
            [frq.store :as store]))

(defn dm?
  "Whether a buffer is a conversation with a person rather than a room. Every
  channel name starts with `#`; what does not is somebody's nick."
  [name]
  (and (seq name) (not (str/starts-with? name "#"))))

(defn row-id
  "What this client calls a line: the server's name for it where there is one,
  and the name it was given here where there is not.

  freeq tags a message with a `msgid` and that is a line's identity everywhere
  it matters — a reply points at one, an edit rewrites one, a reaction lands on
  one. But not every line arrives with one: a replayed backlog can come over
  with no tags at all, and a line this client has just sent has none until the
  server echoes it back.

  Those lines are not nameless to the reader, though. They are on the screen,
  they are in the overview, and pressing one should go to it — so `frq.state`
  gives them a `:local-id` made out of what they are. It is never sent: a
  reply, an edit and a reaction all name a message to the server, and the
  server knows only the names it gave out. This is for everything that is the
  client's own business with a line — which one to scroll to, and which one to
  mark when it gets there."
  [m]
  (or (:id m) (:local-id m)))

(defn last-preview [buffer]
  (if-let [m (last (:messages buffer))]
    (str (:from m) ": " (:text m))
    "No messages yet"))

(defn channel-list
  "Buffers most recently opened first, filtered by the search box.

  A conversation list is read from the top, and the one you were just in is the
  one you are most likely to want again. Buffers never opened — a DM that
  arrived, a channel someone mentioned — sort under those, by name, rather than
  jumping the queue."
  []
  (let [q (str/lower-case (str/trim @cells/search))]
    (->> (vals @cells/channels)
         (filter #(or (str/blank? q)
                      (str/includes? (str/lower-case (:name %)) q)))
         (sort-by (juxt #(- (:accessed % 0)) :name))
         vec)))


(defn mine?
  "Whether we are the one who said this.

  Nick against nick, which is what the server itself falls back to for an
  account with no DID — and an edit it would refuse is one not worth offering.
  A system line is nobody's to rewrite."
  [m me]
  (and (not (:system? m))
       (seq (or (:from m) ""))
       (= (str/lower-case (:from m))
          (str/lower-case (or me "")))))


;; How many lines the overview holds in all.
(def overview-limit 100)

(defn- round-robin
  "The colls' firsts, then their seconds, and so on until they are spent.

  This is how the overview stays about every room while still being a fixed
  number of lines. Taking the newest hundred outright would be the strip
  answering about whichever room is busiest — which is the one you can already
  see. A turn each means a room that said one thing all day is in the first
  handful, beside the room that has said a hundred."
  [colls]
  (lazy-seq
   (let [colls (remove empty? colls)]
     (when (seq colls)
       (concat (map first colls)
               (round-robin (map rest colls)))))))

(defn recent-everywhere
  "The newest lines from every buffer at once, newest first, and at most
  `overview-limit` of them — a turn to each room until they run out.

  Each carries the room it was said in, since that is the one thing a line
  taken out of its own conversation no longer says for itself.

  Bounded per room before anything else, so the cost is the number of rooms
  rather than the length of their backlogs: a channel with a week of history
  in it must not make this the most expensive thing on the screen.

  Joins, parts and the rest of the system's own chatter are left out. They are
  the noise this strip would drown in: a room nobody has spoken in for a day
  still reports everyone who came and went in it.

  So is the room being read. It is on the screen already, in full, directly
  above — repeating its last three lines under itself spends the strip's room
  saying what the conversation just said, and what the strip is for is the
  rooms you are not looking at."
  []
  (->> (dissoc @cells/channels @cells/current)
       (map (fn [[name buffer]]
              ;; Newest first, which is the order a turn each has to be taken
              ;; in: the first round is every room's latest line.
              (->> (:messages buffer)
                   (remove :system?)
                   (take-last overview-limit)
                   reverse
                   (map #(assoc % :channel name)))))
       (remove empty?)
       round-robin
       (take overview-limit)
       ;; Newest at the top, which is the other way round from a conversation
       ;; and right for the same reason a conversation is the way it is: what
       ;; you came to the strip for is what has just happened, and a list you
       ;; have to scroll to the bottom of to find it is a list that answers
       ;; last. The turn-taking above is about which lines are in it, not
       ;; about where they sit.
       (sort-by #(or (:at %) 0) >)))


;; ------------------------------------------------------------- the marker
;; What has been seen, and what the unread count is derived from. Shared for
;; the reason the list is: a marker that only one half keeps is a phone that
;; comes back to a hundred lines it has already read.

(defn after-marker
  "The messages in `buffer` the reader has not seen: everything after its read
  marker.

  By id where the marked message is still held, and by time otherwise. The id
  is the exact answer — a msgid survives every revision, so it names the same
  line however often the server replays it — and the timestamp is what answers
  when the marked line has fallen off the end of the buffer or was never in
  this run's copy of it.

  Derived rather than counted, because a count cannot survive what the server
  does: a JOIN replays the backlog and CHATHISTORY replays it again, and every
  line of it would tick a counter a second time. Against a marker a replayed
  line is simply older than it and counts for nothing."
  [buffer]
  (let [id (:last-read-id buffer)
        at (:last-read-at buffer 0)
        msgs (vec (:messages buffer))]
    (if (and id (some #(= id (:id %)) msgs))
      (vec (rest (drop-while #(not= id (:id %)) msgs)))
      (filterv #(> (:at % 0) at) msgs))))

(defn mentions-me?
  "Whether a line is addressed at the reader by name. Our own lines do not
  count — saying your own nick is not being called."
  [m]
  (let [me (str/trim (or @cells/form-nick ""))]
    (and (seq me)
         (not= (:from m) me)
         (str/includes? (str/lower-case (or (:text m) ""))
                        (str/lower-case me)))))

(defn recount
  "Answer what the marker says: how many lines are unseen, and whether any of
  them names the reader."
  [buffer]
  ;; Joins, parts, quits and "Joined #room" are the room talking about itself,
  ;; not somebody talking in it. They arrive stamped now — the join notice is
  ;; written the moment we are in — so counted, every room you are a member of
  ;; sits at one unread from the moment it opens, saying only that you joined
  ;; it. The marker still moves past them: they are read, they are just never
  ;; what made a room worth looking at.
  (let [fresh (remove :system? (after-marker buffer))]
    (assoc buffer
           :unread (count fresh)
           :mention? (boolean (some mentions-me? fresh)))))

(defn mark-read
  "Move the marker to the newest line this buffer holds. Both halves: the id
  for as long as that line is here, and its time for after it is gone.

  The time only ever goes forward. A backlog can arrive after the reader has
  already read past it, and taking the last line's time unconditionally would
  walk the marker backwards and re-unread what was read."
  [buffer]
  (let [newest (last (:messages buffer))]
    (assoc buffer
           :unread 0
           :mention? false
           :last-read-id (:id newest)
           :last-read-at (max (:last-read-at buffer 0) (:at newest 0)))))

;; How far back a room nobody has seen before counts as already read.
;;
;; A room being joined for the first time replays its whole history, and none
;; of that is news — the reader was not away for it, they were not here. So a
;; new buffer starts caught up rather than at the beginning, or joining a busy
;; channel announces a hundred unread posts from before you arrived.
;;
;; Caught up to a minute ago rather than to this instant, because a live line
;; is timestamped by the server and this by our clock: the two disagree by
;; whatever the skew is, and a live message stamped a few seconds behind us
;; would land under the marker and never be counted. A minute is more skew than
;; there will be and far less than the age of any backlog, and what it costs is
;; that a message sent in the minute before you joined counts as unread — which
;; is the harmless direction.
(def fresh-room-grace-ms 60000)

(defn ensure-channel [m name]
  (if (contains? m name)
    m
    (assoc m name {:name name :messages [] :unread 0
                   :joined? false :joining? false :accessed 0
                   ;; What has been seen, and what the count is derived from.
                   ;; `:unread` and `:mention?` are answers, not records — see
                   ;; `recount`.
                   :last-read-id nil :mention? false
                   :last-read-at (max 0 (- (clock/now-ms) fresh-room-grace-ms))
                   :kind (if (dm? name) :dm :channel)
                   :peer-did nil :last-activity 0
                   ;; nick -> mode prefix, for the people panel
                   :users {}})))

;; ---------------------------------------------------------------- the list
;; A counter rather than a clock: the list only needs their order, and a
;; monotonic tick cannot be surprised by the system time moving.
(defonce access-tick (atom 0))

(defn room-records
  "The rooms as they go to disk: what each one is, when it last said anything,
  and how far into it the reader has got.

  Every room, not only the ones that have been opened. Being in a channel is
  what makes it yours; opening it only says which you looked at last, and that
  is what `:accessed` orders them by. Writing down the opened ones alone is how
  a client in a dozen channels came back knowing one — the rest were left for
  the server to remember, which is the thing it does not do.

  `:unread` and `:mention?` are not written. They are what the marker adds up
  to against the messages in hand, and a count written down is a count that can
  be wrong — the marker cannot be. `:mention?` rides along all the same, as the
  one thing that cannot be recomputed before the history it was derived from
  comes back: a room that had your name in it says so on the next run's first
  frame rather than a round trip later, and is corrected by `recount` the
  moment the backlog lands."
  []
  (->> (vals @cells/channels)
       (sort-by #(- (:accessed % 0)))
       (mapv #(select-keys % [:name :kind :peer-did :last-activity
                              :last-read-id :last-read-at :mention?]))))

(defonce ^:private rooms-saved-at (atom 0))

(defn remember-rooms!
  "Write the room records out, most recently used first: what rooms there are,
  in the order they were last used, and how much of each has been read.

  Throttled, because the marker moves on every line that arrives while a room
  is on screen and a busy channel would otherwise write the file per message.
  `force?` is for the moments worth paying for, which is a room being opened,
  joined or closed.

  A late write costs at most the handful of lines that arrived since the last
  one, shown unread again on the next run. That is the right way round: the
  marker never claims to have read more than it has.

  Shared because both halves have the same thing worth keeping and the same
  moments worth keeping it at. The desktop puts this on a thread of its own as
  well — a jolt answer to a jolt cost, and why `frq.state` keeps its own
  wrapper around `save-rooms!` rather than calling this."
  ([] (remember-rooms! false))
  ([force?]
   (let [now (clock/now-ms)]
     (when (or force? (> (- now @rooms-saved-at) 5000))
       (reset! rooms-saved-at now)
       (store/save-rooms! (room-records))))))

(defn restore-channels!
  "Bring back the rooms of earlier runs, in the order they were last used, each
  with the marker saying how much of it had been read.

  Empty buffers, not memberships: opening one is what joins it, and a list of
  rooms is the part worth keeping — the messages in them come from the server.
  The tick is seeded so this run's first open still sorts above all of them.

  The marker is what makes the returning backlog readable. Without one every
  replayed line is new and every room comes back with its whole history
  unread; with one, the reader is put back where they were and only what
  arrived while they were away is counted. A room migrated from an older frq
  has no marker and is caught up as if read, which is the kinder of the two
  wrong answers — the alternative announces a hundred unread lines the reader
  has already seen."
  []
  (when-let [saved (seq (store/load-rooms))]
    (let [ordered (reverse saved)]                 ; oldest first, so ticks ascend
      (swap! cells/channels
             (fn [m]
               (reduce (fn [acc room]
                         (let [name (:name room)]
                           (if (contains? acc name)
                             acc
                             (assoc acc name
                                    {:name name :messages [] :unread 0
                                     :joined? false :joining? false
                                     :users {}
                                     :kind (or (:kind room)
                                               (if (dm? name) :dm :channel))
                                     :peer-did (:peer-did room)
                                     :last-activity (:last-activity room 0)
                                     :last-read-id (:last-read-id room)
                                     ;; No marker at all — an older frq's list,
                                     ;; or a record that lost it. Read up to
                                     ;; now rather than back to the beginning.
                                     :last-read-at (:last-read-at room
                                                                  (clock/now-ms))
                                     :mention? (boolean (:mention? room))
                                     :accessed (swap! access-tick inc)})))
                         )
                       m
                       ordered))))
    (count saved)))
