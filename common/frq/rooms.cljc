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
