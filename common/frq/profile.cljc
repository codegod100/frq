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

  One gesture opens it, on every backend: a press. A pointer resting on a face
  used to open the card too, with a grace period for crossing from the face to
  it and the card reporting its own pointer back, so that leaving the face was
  not the end of it. That is gone. It made the card something that could arrive
  and leave without being asked for — crossing a column of faces on the way to
  the scrollbar flickered one open per row — and it bought a second way in at
  the price of a dialog that had to be non-modal to be able to close itself.
  Pressing a face is the whole of it now, and what it opens stays until it is
  closed.

  The fetch is a seam, because it is the one part that differs — a future and a
  blocking request on one side, an awaited one on the other. Nothing is fetched
  until a backend installs one, and `entry` simply answers nil."
  (:require [clojure.string :as str]
            [frq.atproto.core :as atproto]
            [frq.cells :as cells]))

(def directory-host atproto/directory-host)

;; actor -> {:status :loading | :ready | :failed, and the fields when ready}.
;;
;; Not one of `frq.cells`: nothing reads the map itself, `profile-tick` is the
;; signal that what it holds has changed, and that is a cell.
(defonce ^:private cache (atom {}))

(def viewing cells/profile-viewing)
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

(defn close!
  "Put the profile away."
  []
  (reset! viewing nil))

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
