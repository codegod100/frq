(ns frq.members
  "Who is in a room, and what the server said to put them there.

  A channel's `:users` is nick -> mode prefix (\"@\", \"+\", or \"\"). The list is
  the server's: NAMES on the way in, and every JOIN, PART, QUIT, KICK, NICK
  and MODE after it. Nothing here asks who is there — being told is what
  membership is.

  Every function takes the channels map and returns a new one, which is the
  only reason this is shared at all: the desktop keeps that map in a glimmer
  ratom and the phone in an ordinary atom, and neither fact is interesting to
  the folding. `frq.state` swaps these in; `frq.main` does the same from a
  Stream.

  What is deliberately *not* here is creating the channel. A room means more
  to the desktop than to the phone — unread counts, read marks, a joining
  flag — so the caller hands in a map that already has the channel in the
  shape it wants, and these only ever touch `:users` and `:names-acc`."
  (:require [clojure.string :as str]))

(def mode-prefixes
  "The characters a server puts in front of a nick in NAMES, and in the same
  order the panel sorts them: owner, admin, op, half-op, voice."
  "~&@%+")

(defn split-prefix
  "One NAMES entry into `[prefix nick]`. A nick never starts with one of these,
  so what is in front of it is a mode and not part of the name."
  [entry]
  (if (and (seq entry) (str/index-of mode-prefixes (subs entry 0 1)))
    [(subs entry 0 1) (subs entry 1)]
    ["" entry]))

(defn with-names
  "One 353 folded into the channel's pending list.

  Pending rather than live: the reply comes in as many lines as it takes and
  ends with 366, and replacing `:users` on each of them would empty the panel
  and refill it a name at a time."
  [m channel names]
  (reduce (fn [m entry]
            (let [[prefix nick] (split-prefix entry)]
              (assoc-in m [channel :names-acc nick] prefix)))
          m
          (remove str/blank? (str/split (or names "") #" "))))

(defn names-done
  "366: the pending list becomes the list."
  [m channel]
  (if-let [acc (get-in m [channel :names-acc])]
    (-> m
        (assoc-in [channel :users] acc)
        (update channel dissoc :names-acc))
    m))

(defn add-user [m channel nick]
  (if (and channel nick)
    (update-in m [channel :users] (fnil assoc {}) nick "")
    m))

(defn remove-user [m channel nick]
  (if (and channel nick (contains? m channel))
    (update-in m [channel :users] dissoc nick)
    m))

(defn remove-everywhere
  "A QUIT names no channel — the person left the server, so they left every
  room this client is watching them in."
  [m nick]
  (reduce-kv (fn [m k v] (assoc m k (update v :users dissoc nick))) {} m))

(defn rename-user
  "A NICK, in every channel the old name was in. Their modes come with them:
  renaming is not leaving."
  [m old new]
  (reduce-kv (fn [m k v]
               (assoc m k
                      (if-let [prefix (get (:users v) old)]
                        (update v :users #(-> % (dissoc old) (assoc new prefix)))
                        v)))
             {}
             m))

(defn with-mode
  "A channel MODE, for the letters that change how someone is listed.

  `args` is whoever the modes were applied to, in order; anything else in the
  mode string — a key, a limit, a ban — names no member and is skipped. A mode
  that takes an argument without naming a member still eats one, and reading
  the next letter's nick out of the wrong place would put a mode on a
  stranger, so only the setting form takes one."
  [m channel modes args]
  (let [letters {\q "~" \a "&" \o "@" \h "%" \v "+"}]
    (loop [m m chars (seq modes) args args adding? true]
      (if-let [c (first chars)]
        (case c
          \+ (recur m (rest chars) args true)
          \- (recur m (rest chars) args false)
          (if-let [prefix (letters c)]
            (let [nick (first args)]
              (recur (if (and nick (get-in m [channel :users nick]))
                       (assoc-in m [channel :users nick] (if adding? prefix ""))
                       m)
                     (rest chars) (rest args) adding?))
            (recur m (rest chars) (if adding? (rest args) args) adding?)))
        m))))

(def ^:private prefix-rank
  (into {"" (count mode-prefixes)}
        (map-indexed (fn [i c] [(str c) i]) mode-prefixes)))

(defn member-list
  "Who is in `channel`, as `{:nick :prefix}`, ops first and then alphabetically
  — the order every other client lists them in, and the one a reader scanning
  for a name expects."
  [m channel]
  (->> (get-in m [channel :users])
       (map (fn [[nick prefix]] {:nick nick :prefix prefix}))
       (sort-by (juxt #(prefix-rank (:prefix %) 99) #(str/lower-case (:nick %))))
       vec))

(defn member-count [m channel]
  (count (get-in m [channel :users])))
