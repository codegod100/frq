(ns frq.rooms
  "What the conversation list is, derived from the cells it is held in.

  Pure, and so shared: `channel-list` is a filter and a sort over
  `frq.cells/channels` and the search box, `dm?` is a question about a name,
  `last-preview` reads the last message of a buffer, `recent-everywhere` is
  the overview strip's list of what is happening in every other room. `frq.state`
  re-defs them all, so the thousand lines below them did not move."
  (:require [clojure.string :as str]
            [frq.cells :as cells]))

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
