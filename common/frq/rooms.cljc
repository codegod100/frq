(ns frq.rooms
  "What the conversation list is, derived from the cells it is held in.

  Pure, and so shared: `channel-list` is a filter and a sort over
  `frq.cells/channels` and the search box, `dm?` is a question about a name,
  `last-preview` reads the last message of a buffer. `frq.state` re-defs all
  three, so the thousand lines below them did not move."
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
