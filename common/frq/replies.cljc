(ns frq.replies
  "Finding the line a reply points at when the buffer does not hold that name.

  A message keeps the id it was born with through every revision, and the
  server gives each revision a msgid of its own — so an answer to a line that
  has already been rewritten names the revision (see `frq.edits`). While this
  client is connected it watches that happen and records both names. A backlog
  is the case it cannot watch: replay sends one collapsed row per message,
  carrying the surviving msgid, the final text and `+freeq.at/edited=1`, and
  the revision's own msgid never crosses the wire at all. Nothing on the line
  says which other names it used to answer to.

  freeq knows, though. `GET /api/v1/messages/{msgid}` answers with
  `replaces_msgid` — the id the revision collapsed into — so one question per
  unresolved reply is enough to tie the two together. The answer is written
  onto the message as another name it answers to, which is the same place a
  live edit puts it, so `frq.rooms/answers-to?` is still the only rule about
  what names a line.

  Asked once per id and never again: `asked` remembers every id this session
  has put the question to, answer or no answer. A chip that cannot be resolved
  is a chip that stays as it is — the screen is redrawn constantly and a miss
  that re-asked would be a request per frame."
  (:require [frq.atproto.core :as atproto]
            [frq.cells :as cells]
            [frq.io :as io]
            [frq.rooms :as rooms]))

(defonce ^:private asked (atom #{}))

(defn forget-asks!
  "Drop what has been asked, for a client signing in again — a new session has
  a new bearer, and an id that failed under the old one deserves another go."
  []
  (reset! asked #{}))

(defn- learn!
  "Record `id` as another name for the message `holds` names, if we hold it."
  [channel id holds]
  (when (and channel id holds)
    (swap! cells/channels
           (fn [chans]
             (if-let [msgs (get-in chans [channel :messages])]
               (assoc-in chans [channel :messages]
                         (mapv (fn [m]
                                 (if (rooms/answers-to? m holds)
                                   (update m :edit-ids (fnil conj #{}) id)
                                   m))
                               msgs))
               chans)))))

(defn resolve!
  "Ask freeq what `id` was, and tie it to the line it collapsed into.

  Does nothing without a bearer — the endpoint refuses an anonymous read of a
  channel you are in — and nothing for an id already asked about. `on-change`
  is called only when something was actually learned, so a caller can repaint
  on it without repainting on every miss."
  [channel id on-change]
  (when (and channel id (not (contains? @asked id)))
    (when-let [bearer (some-> @cells/api-bearer not-empty)]
      (swap! asked conj id)
      (io/fetch-text!
       (str "https://" @cells/form-host "/api/v1/messages/" id)
       {"Authorization" (str "Bearer " bearer)
        "Accept" "application/json"}
       (fn [body]
         (when-let [holds (some-> body (atproto/json-str "replaces_msgid"))]
           (learn! channel id holds)
           (when on-change (on-change))))))))
