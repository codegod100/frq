(ns frq.avatars
  "Profile pictures for the people with an AT Protocol identity behind them.

  freeq gives an authenticated user their handle as their nick — `nandi.uk`
  rather than `sleek5209` — so the nick is the lookup, and a nick that is not
  handle-shaped is a guest with no profile to fetch. One lookup per person
  however many lines they write, kept on disk between runs like any other
  picture.

  The thumbnail preset, and `@png` rather than the CDN's default: the tree
  backend decodes PNG, and 128×128 is what a 24-point avatar needs."
  (:require [clojure.string :as str]
            [frq.profile :as profile]
            [frq.atproto :as atproto]
            [jolt.host :as host]
            [jolt.mvn-http :as http]))

(def ^:private directory-host "public.api.bsky.app")

(def handle?
  "Moved to `frq.profile`, which is what asks: whether a nick is worth looking
  a profile up by is the same question under either compiler."
  profile/handle?)

(def actor profile/actor)

(defn cache-dir []
  (let [xdg (host/getenv "XDG_CACHE_HOME")
        home (host/getenv "HOME")]
    (str (if (seq xdg) xdg (str home "/.cache")) "/frq/avatars")))

(defn cached-path [handle]
  (str (cache-dir) "/" (str/replace (str/lower-case handle) #"[^a-z0-9._-]" "_") ".png"))

;; handle -> :fetching | :ready | :failed
(defonce state (atom {}))

(defn path-when-ready [handle]
  (when (= :ready (get @state handle)) (cached-path handle)))

(defn- thumbnail-url
  "The CDN's full-size avatar URL as a 128-pixel PNG. Asking for the size we
  paint keeps a 170KB portrait from being downloaded to draw at 24 points."
  [url]
  (when (seq url)
    (-> url
        (str/replace "/img/avatar/plain/" "/img/avatar_thumbnail/plain/")
        (str/replace #"@[a-z]+$" "")
        (str "@png"))))

(defn- profile-avatar
  "The avatar URL on someone's profile, or nil if they have none."
  [handle]
  (let [body (atproto/request directory-host
                              (str "/xrpc/app.bsky.actor.getProfile?actor=" handle)
                              nil)]
    (thumbnail-url (atproto/json-str body "avatar"))))

(defn fetch!
  "Ensure this person's avatar is on disk, in the background. Returns without
  waiting; `path-when-ready` answers for it afterwards, and `on-change` says
  when that answer has changed."
  [handle on-change]
  (when (and (seq handle) (not (contains? @state handle)))
    (let [path (cached-path handle)]
      (if (host/file-exists? path)
        (do (swap! state assoc handle :ready) (on-change))
        (do
          (swap! state assoc handle :fetching)
          (future
            (let [ok (try
                       (host/mkdirs! (cache-dir))
                       (http/ensure-native!)
                       (when-let [url (profile-avatar handle)]
                         (and (http/fetch url path)
                              (host/file-exists? path)))
                       (catch Exception _ false))]
              (swap! state assoc handle (if ok :ready :failed))
              (on-change))))))))
