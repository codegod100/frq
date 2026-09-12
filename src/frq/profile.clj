(ns frq.profile
  "Who someone is, behind the nick on a line.

  sleek's peer profile modal, as a screen. Tapping a name or a face in the
  chat opens it: the picture at a size worth looking at, the display name and
  handle, the DID, whatever bio and counts Bluesky holds, and a way through to
  their profile on the web.

  One fetch per person, kept for the run — a profile is looked at repeatedly
  and changes on nobody's timescale. Guests have no identity to fetch, so for
  them the screen is the nick and a line saying so, which is the honest answer
  rather than a spinner that never lands."
  (:require [clojure.string :as str]
            [glimmer.ratom :as r :refer [atom]]
            [frq.atproto :as atproto]
            [frq.avatars :as avatars]
            [frq.platform :as platform]))

(def ^:private directory-host "public.api.bsky.app")

;; Who is being looked at, or nil — `{:nick :actor}`, where `actor` is the DID
;; or handle `frq.avatars/actor` worked out, and nil for a guest.
(defonce viewing (atom nil))

;; actor -> {:status :loading | :ready | :failed, and the fields when ready}
(defonce ^:private cache (atom {}))

;; Bumped when a fetch lands, so the screen re-renders without watching the
;; cache map itself — the same trick the chat view uses for pictures.
(defonce tick (atom 0))

(defn- parse
  "The fields the screen paints, out of an `app.bsky.actor.getProfile` body."
  [body]
  {:status :ready
   :did (atproto/json-str body "did")
   :handle (atproto/json-str body "handle")
   :display-name (some-> (atproto/json-str body "displayName")
                         atproto/json-unescape
                         str/trim
                         not-empty)
   :description (some-> (atproto/json-str body "description")
                        atproto/json-unescape
                        str/trim
                        not-empty)
   :followers (atproto/json-num body "followersCount")
   :follows (atproto/json-num body "followsCount")
   :posts (atproto/json-num body "postsCount")})

(defn entry
  "What is known about this person right now, or nil before anything is."
  [actor]
  (get @cache actor))

(defn fetch!
  "Ensure this person's profile is on its way, in the background. Returns
  without waiting; `entry` answers for it afterwards and `tick` says when that
  answer has changed."
  [actor]
  (when (and (seq actor) (not (contains? @cache actor)))
    (swap! cache assoc actor {:status :loading})
    (future
      (let [got (try
                  (let [body (atproto/request
                              directory-host
                              (str "/xrpc/app.bsky.actor.getProfile?actor=" actor)
                              nil)]
                    (when (atproto/json-str body "did")
                      (parse body)))
                  (catch Exception _ nil))]
        (swap! cache assoc actor (or got {:status :failed}))
        (swap! tick inc)))))

(defn open!
  "Look at someone. `actor` is their DID or handle, or nil for a guest."
  [nick actor]
  (reset! viewing {:nick nick :actor actor})
  ;; The picture too: the chat asks for one when a line arrives, but this
  ;; screen can be opened on someone whose avatar never landed, and it paints
  ;; a bigger one than the column it was fetched for.
  (when (seq actor) (avatars/fetch! actor #(swap! tick inc)))
  (fetch! actor))

(defn close! [] (reset! viewing nil))

;; The face the pointer is resting on, or nil — `{:nick :actor}`, the same
;; shape as `viewing`. A card is painted for this one alone rather than hung
;; under every avatar in the column: the tree keeps whatever it is given, and
;; a channel's worth of unseen profile cards is a tree nobody looks at.
(defonce hovering (atom nil))

(defn hover!
  "The pointer has come to rest on someone's face. Starts the same two fetches
  opening them would, so the card has something on it by the time it is read."
  [nick actor]
  (reset! hovering {:nick nick :actor actor})
  (when (seq actor) (avatars/fetch! actor #(swap! tick inc)))
  (fetch! actor))

;; Whether the pointer is on the dialog the hover put up.
;;
;; This is what makes a hovered profile something you can move into and read
;; rather than something you can only glance at: the dialog reports its own
;; pointer, so leaving the face is not the end of the hover if the pointer
;; turned up here instead.
(defonce ^:private over-dialog? (atom false))

(defn dismiss!
  "Put the profile away, however it was opened.

  The dialog is shown for `viewing` or for `hovering`, so a Close that cleared
  only the first left one the pointer had opened on screen with its own button
  doing nothing to it."
  []
  (reset! viewing nil)
  (reset! hovering nil)
  ;; And the pointer's claim on it. Close takes the dialog out from under the
  ;; pointer, so there is no leaving edge coming to say so — left set, it
  ;; would hold the next hover open for good.
  (reset! over-dialog? false))

;; How long the pointer may be on neither the face nor the dialog before the
;; dialog goes.
;;
;; There is a gap between the two — the dialog is centred and the face is
;; wherever the message is — and a hover that ended the instant the pointer
;; left the face would close it halfway across every time. Long enough to
;; cross, short enough that a pointer moving somewhere else entirely does not
;; drag it along.
(def ^:private grace-ms 400)

(defn- release!
  "Let `nick`'s hover go, unless something has taken it up again.

  Three things can have happened in the grace period: the pointer arrived on
  the dialog, it went back to the face, or it landed on someone else's. In all
  three there is a hover to keep, and it is not this one's to end — which is
  what the nick guard says."
  [nick]
  (when-not @over-dialog?
    (swap! hovering #(when-not (= nick (:nick %)) %))))

(defn unhover!
  "The pointer has left `nick`'s face — which is not yet the end of it.

  Guarded by who is being left, so the leaving of one face cannot take down
  the card of the next one: both edges arrive in the same frame when the
  pointer crosses straight over."
  [nick]
  (platform/after! grace-ms #(release! nick)))

(defn enter-dialog!
  "The pointer is on the dialog. Whatever hover put it there is now this."
  []
  (reset! over-dialog? true))

(defn leave-dialog!
  "The pointer has left the dialog, and with it the last thing holding the
  profile open — unless it went back to the face it came from."
  []
  (reset! over-dialog? false)
  (let [nick (:nick @hovering)]
    (platform/after! grace-ms #(release! nick))))

(defn web-url
  "Their profile on the web, by handle where there is one and DID otherwise."
  [{:keys [handle did]}]
  (let [who (or (not-empty (str/trim (or handle ""))) did)]
    (when (seq who)
      (str "https://bsky.app/profile/" (str/replace who #"^@" "")))))

(defn stats-line
  "\"12 followers · 34 following · 56 posts\", or nil when none are known."
  [{:keys [followers follows posts]}]
  (let [parts (cond-> []
                followers (conj (str followers " followers"))
                follows (conj (str follows " following"))
                posts (conj (str posts " posts")))]
    (when (seq parts) (str/join " · " parts))))

(defn truncate
  "A bio cut to `max` characters, keeping its line breaks — the height of a
  multi-line bio is part of what it says."
  [s max]
  (let [t (str/trim (or s ""))]
    (if (<= (count t) max)
      t
      (str (subs t 0 (dec max)) "…"))))
