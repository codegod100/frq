(ns frq.media
  "Images in messages: spot the links, fetch them once, keep them on disk.

  The picture itself is painted by Vidya's `:image` node from a file, so all
  this has to do is turn a URL into a path — off the UI thread, one fetch per
  URL however many messages carry it, and never twice across runs."
  (:require [clojure.string :as str]
            [jolt.host :as host]
            [jolt.mvn-http :as http]))

;; PNG only: it is what the tree backend decodes, and what freeq's own media
;; endpoint serves. A .jpg link stays a link.
(def ^:private image-pattern #"https?://[^\s]+\.png")

(defn image-urls
  "Every image link in a message, in the order they appear."
  [text]
  (vec (distinct (re-seq image-pattern (or text "")))))

(defn cache-dir []
  (let [xdg (host/getenv "XDG_CACHE_HOME")
        home (host/getenv "HOME")]
    (str (if (seq xdg) xdg (str home "/.cache")) "/frq/media")))

(defn- cache-name
  "A filename for a URL: its own last segment behind a hash of the whole thing,
  so two `image.png` from different messages do not collide."
  [url]
  (let [h (Math/abs (hash url))
        tail (-> url (str/split #"/") last (str/replace #"[^A-Za-z0-9._-]" ""))]
    (str h "-" (subs tail (max 0 (- (count tail) 40))))))

(defn cached-path [url] (str (cache-dir) "/" (cache-name url)))

;; url -> :fetching | :ready | :failed
(defonce state (atom {}))

(defn status [url] (get @state url))

(defn path-when-ready [url]
  (when (= :ready (get @state url)) (cached-path url)))

(defn fetch!
  "Ensure the image behind `url` is on disk, in the background. Returns without
  waiting; `path-when-ready` answers for it afterwards. `on-change` is called
  when the answer changes, so a UI can repaint."
  [url on-change]
  (when-not (contains? @state url)
    (let [path (cached-path url)]
      (if (host/file-exists? path)
        (do (swap! state assoc url :ready) (on-change))
        (do
          (swap! state assoc url :fetching)
          (future
            (let [ok (try
                       (host/mkdirs! (cache-dir))
                       (http/ensure-native!)
                       (and (http/fetch url path)
                            (host/file-exists? path))
                       (catch Exception _ false))]
              (swap! state assoc url (if ok :ready :failed))
              (on-change))))))))
