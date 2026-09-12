(ns frq.profile.pointer
  "What a pointer does about a profile, and how this half fetches one.

  `frq.profile` under common/ is what a profile *is* — the cache, the fields,
  the URL, the counts — and both halves share it. This is the rest, and it is
  all desktop by nature: hovering a face, the grace period for crossing from
  the face to the card, and the card reporting its own pointer so moving into
  it is not the same as leaving. A phone has none of those; a finger is either
  on a name or not on it.

  The fetch lives here too, because a `future` and a blocking request is this
  backend's answer to a question the other one answers by awaiting."
  (:require [frq.atproto :as atproto]
            [frq.avatars :as avatars]
            [frq.platform :as platform]
            [frq.profile :as profile]))

;; The shared names, re-exported so callers did not move.
(def viewing profile/viewing)
(def hovering profile/hovering)
(def tick profile/tick)
(def entry profile/entry)
(def close! profile/close!)
(def web-url profile/web-url)
(def stats-line profile/stats-line)
(def truncate profile/truncate)

(profile/install-fetch!
 (fn [actor]
   (future
     (profile/deliver-profile!
      actor
      (try
        (let [{:keys [host path]} (profile/profile-req actor)]
          (atproto/request host path nil))
        (catch Exception _ nil))))))

(defn- with-avatar!
  "The picture too. The chat asks for one when a line arrives, but a profile
  can be opened on someone whose avatar never landed, and it paints a bigger
  one than the column it was fetched for."
  [actor]
  (when (seq actor) (avatars/fetch! actor #(swap! tick inc))))

(defn open!
  "Look at someone. `actor` is their DID or handle, or nil for a guest."
  [nick actor]
  (with-avatar! actor)
  (profile/open! nick actor))

;; Whether the pointer is on the dialog the hover put up.
;;
;; This is what makes a hovered profile something you can move into and read
;; rather than something you can only glance at: the dialog reports its own
;; pointer, so leaving the face is not the end of the hover if the pointer
;; turned up here instead.
(defonce ^:private over-dialog? (atom false))

(defn hover!
  "The pointer has come to rest on someone's face. Starts the same two fetches
  opening them would, so the card has something on it by the time it is read."
  [nick actor]
  (reset! hovering {:nick nick :actor actor})
  (with-avatar! actor)
  (profile/fetch! actor))

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
