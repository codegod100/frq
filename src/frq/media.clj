(ns frq.media
  "Images in messages: spot the links, fetch them once, keep them on disk.

  The picture itself is painted by Vidya's `:image` node from a file, so all
  this has to do is turn a URL into a path — off the UI thread, one fetch per
  URL however many messages carry it, and never twice across runs.

  The naming half of it is not here: which links are pictures and what the
  file behind one is called are things the Flutter half has to agree with, so
  they live in `frq.media.core` under ../common and this is the jolt fetching
  around them."
  (:require [frq.media.core :as core]
            [jolt.host :as host]
            [jolt.mvn-http :as http]))

(def image-urls core/image-urls)

(defn cache-dir []
  (let [xdg (host/getenv "XDG_CACHE_HOME")
        home (host/getenv "HOME")]
    (str (if (seq xdg) xdg (str home "/.cache")) "/frq/media")))

(defn cached-path [url] (core/cached-path (cache-dir) url))

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
