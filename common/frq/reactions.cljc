(ns frq.reactions
  "The tally of who put what on a message.

  A message's `:reactions` is emoji -> the nicks who are on it. Pure over the
  channels map, like `frq.members`, and shared for the same reason: the rules
  are the server's and neither half of frq gets a say in them.

  What a reaction is *sent* as lives in `frq.irc.mutate`; this is only what
  the buffer does about one, whether it came from the server or from the
  reader pressing a pill here."
  (:require [clojure.string :as str]
            [frq.cells :as cells]
            [frq.emoji :as emoji]))

(defn parse-tally
  "The server's tally of what is already on a message, as
  `emoji:nick,nick;emoji:nick` — what CHATHISTORY sends so reactions survive a
  reconnect rather than starting empty every time the app opens."
  [encoded]
  (when (seq (or encoded ""))
    (reduce (fn [acc part]
              (let [[emoji nicks] (str/split part #":" 2)]
                (if (and (seq emoji) (seq (or nicks "")))
                  (assoc acc emoji (vec (remove str/blank? (str/split nicks #","))))
                  acc)))
            {}
            (str/split encoded #";"))))

(defn with-reaction
  "One nick's reaction added to or taken off a tally. An emoji nobody is left
  on goes away with them: an empty pill is a pill that says nothing."
  [reactions emoji nick on?]
  (let [nicks (vec (get reactions emoji []))
        nicks (if on?
                (if (some #{nick} nicks) nicks (conj nicks nick))
                (vec (remove #{nick} nicks)))]
    (if (seq nicks)
      (assoc reactions emoji nicks)
      (dissoc reactions emoji))))

(defn mine?
  "Whether `nick` is already on that emoji — which is what makes a second
  press take it off rather than send the same reaction twice."
  [m emoji nick]
  (boolean (some #{nick} (get (:reactions m) emoji))))

(defn update-reaction
  "One reaction folded into the buffer it belongs to.

  The message it names may not be there — a reaction on something older than
  the backlog we asked for — and then there is nothing to show it on, so
  nothing happens."
  [channels channel msgid emoji nick on?]
  (if (and channel msgid (seq (or emoji "")))
    (if-let [msgs (get-in channels [channel :messages])]
      (assoc-in channels [channel :messages]
                (mapv (fn [msg]
                        (if (= msgid (:id msg))
                          (update msg :reactions with-reaction emoji nick on?)
                          msg))
                      msgs))
      channels)
    channels))

(defn peer-did
  "The DID of whoever this DM buffer is with, from the last thing they said.

  nil for a channel, and for a conversation where nobody with a DID has spoken
  — a signature over a DM needs both sides named, and there is nothing to
  name."
  [channels channel me]
  (when-not (str/starts-with? (or channel "") "#")
    (->> (get-in channels [channel :messages])
         (remove #(= me (:from %)))
         (keep :did)
         last)))


;; --------------------------------------------------------------- the picker

(defn picker-emoji
  "What the picker is showing right now: the popular row, one group, or
  whatever the search matches — by name, so \"cat\" finds the cat and the cat
  face, and by the emoji itself, so pasting one finds it."
  []
  (let [q (str/lower-case (str/trim (str @cells/emoji-search)))
        ;; A blank group is no group: the popular row is what nothing selected
        ;; means, and an empty string would filter the catalog down to nothing.
        group (when (seq (str (or @cells/emoji-group ""))) @cells/emoji-group)]
    (cond
      (seq q) (->> emoji/catalog
                   (filter (fn [[glyph name _]]
                             (or (str/includes? (str/lower-case name) q)
                                 (str/includes? glyph q))))
                   vec)
      group (vec (filter (fn [[_ _ g]] (= g group)) emoji/catalog))
      :else (mapv (fn [glyph] [glyph glyph nil]) emoji/popular))))
