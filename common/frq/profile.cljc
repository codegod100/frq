(ns frq.profile
  "Who someone is, behind the nick on a line.

  sleek's peer profile modal, as a screen. Tapping a name or a face opens it:
  the picture at a size worth looking at, the display name and handle, the DID,
  whatever bio and counts Bluesky holds, and a way through to their profile on
  the web.

  One fetch per person, kept for the run — a profile is looked at repeatedly
  and changes on nobody's timescale. Guests have no identity to fetch, so for
  them the screen is the nick and a line saying so, which is the honest answer
  rather than a spinner that never lands.

  What a pointer does about one is here too, at the foot of this file: hovering
  a face, the grace period for crossing from the face to the card, and the card
  reporting its own pointer. That used to be jolt's alone, on the reading that
  a pointer meant libcosmic — but `just flutter-desktop` is a window with a
  mouse in it as much as `just cosmic run` is, and the machine is a few atoms
  and a timer with nothing host-shaped in it. The timer is the one thing that was,
  and `frq.io/after!` is where that went. Whether there is a pointer at all is
  still the host's answer: `actions/desktop?`.

  The fetch is a seam, because it is the one part that differs — a future and a
  blocking request on one side, an awaited one on the other. Nothing is fetched
  until a backend installs one, and `entry` simply answers nil."
  (:require [clojure.string :as str]
            [frq.atproto.core :as atproto]
            [frq.cells :as cells]
            [frq.io :as io]))

(def directory-host atproto/directory-host)

;; actor -> {:status :loading | :ready | :failed, and the fields when ready}.
;;
;; Not one of `frq.cells`: nothing reads the map itself, `profile-tick` is the
;; signal that what it holds has changed, and that is a cell.
(defonce ^:private cache (atom {}))

(def viewing cells/profile-viewing)
(def hovering cells/profile-hovering)
(def tick cells/profile-tick)

;; A handle is a domain: labels joined by dots, ending in something alphabetic.
;; An IRC nick cannot be one by accident — `sleek5209` and `eve` are not.
(def ^:private handle-pattern
  ;; Spelled out rather than `(?i)`: Dart's RegExp has no inline flag syntax
  ;; and rejects the whole pattern with "FormatException: Invalid group" — at
  ;; the moment the first message arrives, which is a crash on connect rather
  ;; than anything you see when the screen is drawn. This file is `common/`, so
  ;; it has to be a pattern both engines read the same way.
  #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)*\.[A-Za-z]{2,}$")

(defn handle?
  "Whether this nick is an AT Protocol handle, and so worth a lookup."
  [nick]
  (boolean (and nick (re-matches handle-pattern nick))))

(defn actor
  "The identity to look a profile up by, or nil when there is none.

  A DID from the message's `account` tag when the server sent one — it is the
  identity itself, and holds whatever the nick happens to be today. Otherwise
  the nick, but only when it is handle-shaped: freeq gives an authenticated
  user their handle by default, while `sleek5209` is a guest with no profile."
  [did nick]
  (cond
    (and did (str/starts-with? (str did) "did:")) did
    (handle? nick) nick
    :else nil))

(defn profile-req
  "Ask the directory who this is.

  The actor goes in unescaped, as it always has: a handle is a domain name and
  a DID is `did:` and base32, and neither carries a character a query string
  would mind."
  [actor]
  {:host directory-host
   :path (str "/xrpc/app.bsky.actor.getProfile?actor=" actor)})

(defn thumbnail-url
  "The CDN's full-size avatar URL as a 128-pixel PNG. Asking for the size we
  paint keeps a 170KB portrait from being downloaded to draw at 24 points.

  Here rather than in `frq.avatars` because `frq.avatars` is jolt's: the phone
  needs the same rewrite off the same `getProfile` body, and the rule for a
  string transformation both halves need is that it lives in `common/`."
  [url]
  (when (seq (str (or url "")))
    (-> url
        (str/replace "/img/avatar/plain/" "/img/avatar_thumbnail/plain/")
        (str/replace #"@[a-z]+$" "")
        (str "@png"))))

(defn avatar-url
  "The thumbnail URL on this `app.bsky.actor.getProfile` body, or nil when the
  person has no picture."
  [body]
  (thumbnail-url (atproto/json-str body "avatar")))

(defn parse
  "The fields the screen paints, out of an `app.bsky.actor.getProfile` body."
  [body]
  {:status :ready
   :did (atproto/json-str body "did")
   :avatar (avatar-url body)
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

;; The backend's fetcher: called with the actor, and expected to land the
;; answer through `deliver-profile!` whenever it arrives.
(defonce ^:private fetcher (atom nil))

(defn install-fetch!
  "How this backend asks the directory. See the ns docstring."
  [f]
  (reset! fetcher f))

(defn deliver-profile!
  "What came back, however it was fetched. `body` nil means it did not."
  [actor body]
  (swap! cache assoc actor
         (or (when (and body (atproto/json-str body "did")) (parse body))
             {:status :failed}))
  (swap! tick inc))

(defn fetch!
  "Ensure this person's profile is on its way. Returns without waiting;
  `entry` answers for it afterwards and `tick` says when that has changed."
  [actor]
  (when (and (seq (str (or actor ""))) (not (contains? @cache actor)))
    (swap! cache assoc actor {:status :loading})
    (when-let [f @fetcher] (f actor))))

(defn open!
  "Look at someone. `actor` is their DID or handle, or nil for a guest."
  [nick actor]
  (reset! viewing {:nick nick :actor actor})
  (fetch! actor))

(defn close! [] (reset! viewing nil))

;; ------------------------------------------------------- what a pointer does

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

(defn hover!
  "The pointer has come to rest on someone's face. Starts the fetch opening
  them would, so the card has something on it by the time it is read.

  Their picture is not asked for here. It is the one part of this that needs
  the host — the desktop downloads a file and the phone hands the CDN URL
  straight to the widget — so each backend asks for it at the seam, beside the
  call to this."
  [nick actor]
  (reset! hovering {:nick nick :actor actor})
  (fetch! actor))

(defn unhover!
  "The pointer has left `nick`'s face — which is not yet the end of it.

  Guarded by who is being left, so the leaving of one face cannot take down
  the card of the next one: both edges arrive in the same frame when the
  pointer crosses straight over."
  [nick]
  (io/after! grace-ms #(release! nick)))

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
    (io/after! grace-ms #(release! nick))))

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
