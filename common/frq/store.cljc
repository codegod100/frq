(ns frq.store
  "The one thing worth keeping between runs: the durable broker token.

  It is a credential — anyone holding it can mint session tokens for the
  account — so it lives in the user's config directory with the permissions of
  an ssh key, and never anywhere else. The web-token beside it is single-use
  and deliberately not saved."
  (:require [clojure.edn :as edn]
            [frq.io :as io]))

(defn config-dir
  "Where this client's files go. The platform's answer, not a rule about XDG:
  see `frq.io/config-dir` — Android has no HOME to be relative to."
  []
  (io/config-dir))

(defn session-file [] (str (config-dir) "/session.edn"))

(defn load-session
  "The saved session, or nil. A file that will not parse is treated as absent —
  a stale credential is not worth an error at startup."
  []
  (let [path (session-file)]
    (when (io/file-exists? path)
      (try
        (let [m (edn/read-string (io/slurp path))]
          (when (and (map? m) (seq (:broker-token m))) m))
        (catch Exception _ nil)))))

(defn save-session!
  "Write {:broker-token :handle :did :nick}, readable by nobody else."
  [session]
  (let [dir (config-dir)
        path (session-file)]
    (try
      (io/mkdirs! dir)
      ;; Through the seam rather than a chmod: what matters is that nobody else
      ;; can read it, and each platform makes that guarantee its own way — the
      ;; desktop creates the file at mode 600 before writing a byte into it,
      ;; Android gets app-private storage from the system.
      (io/write-private-file!
       path (pr-str (select-keys session [:broker-token :handle :did :nick])))
      (catch Exception _ false))))

(defn channels-file [] (str (config-dir) "/channels.edn"))

(defn load-channels
  "The channels an older frq wrote: names alone, most recently used first.
  Read only to migrate them into `rooms.edn`, which says the same and more —
  nothing writes this file any more."
  []
  (let [path (channels-file)]
    (when (io/file-exists? path)
      (try
        (let [v (edn/read-string (io/slurp path))]
          (when (vector? v) (filterv string? v)))
        (catch Exception _ nil)))))

(defn rooms-file [] (str (config-dir) "/rooms.edn"))

(defn load-rooms
  "The rooms this client knows, most recently used first, each carrying the
  read marker that says how much of it has been seen.

  This is the authority for what rooms exist. The server forgets them — it has
  told us we are in rooms we are not and left out ones we are — so a room is
  gone when the reader closes it here and not before.

  A record that will not parse is dropped rather than defaulted: a room with a
  broken marker would count its whole history unread, which is worse than a
  room that starts over. An older frq's `channels.edn` migrates in as names
  with no marker, which is exactly what it knew."
  []
  (let [path (rooms-file)]
    (or (when (io/file-exists? path)
          (try
            (let [v (edn/read-string (io/slurp path))]
              (when (vector? v)
                (filterv #(and (map? %) (string? (:name %)) (seq (:name %))) v)))
            (catch Exception _ nil)))
        (when-let [names (seq (load-channels))]
          (mapv (fn [n] {:name n}) names)))))

(defn save-rooms!
  "Write the room records, most recently used first."
  [rooms]
  (try
    (io/mkdirs! (config-dir))
    (io/spit (rooms-file) (pr-str (vec rooms)))
    (catch Exception _ false)))

(defn clear-session! []
  (try
    (when (io/file-exists? (session-file))
      (io/delete-file! (session-file)))
    true
    (catch Exception _ false)))

(defn prefs-file [] (str (config-dir) "/prefs.edn"))

(defn load-prefs
  "The user's settings, or an empty map. Like the channel list beside it these
  are names and flags rather than secrets, so it is an ordinary file — and one
  that will not parse is treated as absent rather than as an error worth
  stopping the launch for."
  []
  (let [path (prefs-file)]
    (or (when (io/file-exists? path)
          (try
            (let [m (edn/read-string (io/slurp path))]
              (when (map? m) m))
            (catch Exception _ nil)))
        {})))

(defn save-prefs!
  "Write the settings map whole. There are few enough of them that merging is
  the caller's job, and a partial write would silently drop the rest."
  [prefs]
  (try
    (io/mkdirs! (config-dir))
    (io/spit (prefs-file) (pr-str prefs))
    (catch Exception _ false)))
