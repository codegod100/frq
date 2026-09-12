(ns frq.cosmic
  "frq's own screens, painted by libcosmic. The desktop entry point.

  The same trick as `frq.tui`: the components in `frq.app` do not know what is
  under the reconciler, so requiring `glimmer-cosmic.core` after `frq.app`
  makes it the backend glimmer renders with. Nothing in `frq.app` changes.

  glimmer-cosmic is a spike, and it shows. It paints a short list of tags and
  treats every other one as a column, so most of frq comes out as stacked text
  and buttons rather than its real layout. The jvui calls frq makes elsewhere
  (a picture chooser, call frames) have no window of their own to act on and do
  nothing, the same way they do in the terminal.

  The one real difference from the other two: libcosmic takes the main thread
  and keeps it, so glimmer's loop runs on a worker. The timers handed to
  `start!` are glimmer-cosmic's, which run on that worker.

    just cosmic run"
  (:require [frq.app :as app]
            [frq.platform :as platform]
            [frq.state :as s]
            [glimmer.core :as ui]
            [glimmer-cosmic.ffi :as cosmic-ffi]
            ;; last, so its install! is the one that stands
            [glimmer-cosmic.core :as cosmic]))

(defn- dump-tree-to!
  "Write the tree as the reconciler left it to `path` every few seconds.

  There is no REPL into a libcosmic window — it owns the main thread — so this
  is how to tell a row that is not in the tree from a row that is in it and not
  painted. Off unless FRQ_COSMIC_DUMP names a file."
  [path]
  (cosmic/every! 3000 #(spit path (cosmic/dump-str))))

(defn- open-url!
  "Hand a URL to the desktop's browser.

  libcosmic has none of its own, so this is xdg-open — which is what the
  desktop's answer to \"show me this page\" has always been, and what
  `frq.platform/open-url!` means by a backend that has a browser to hand it
  to. Detached and its output thrown away: frq is not waiting on it, and a
  child whose pipes nobody reads is a child that can block on a full one.

  http and https only. Every link in a conversation reaches this from
  somewhere else's message, and xdg-open takes far more than a web page — a
  `file:` URL is a file manager, and a bare path is whatever is registered for
  it. A scheme this client did not mean to offer is not opened at all."
  [url]
  (boolean
   (when (re-matches #"(?i)https?://[^\s]+" (str url))
     (try
       (-> (ProcessBuilder. (into-array String ["xdg-open" url]))
           (.redirectOutput java.lang.ProcessBuilder$Redirect/DISCARD)
           (.redirectError java.lang.ProcessBuilder$Redirect/DISCARD)
           (.start))
       true
       (catch Exception _ false)))))

(defn -main [& _]
  ;; Everything this backend can do. What is missing is missing on purpose:
  ;; libcosmic has no texture to push call frames into, which is the same
  ;; thing `:av? false` below says from the other end. It has no browser
  ;; either, but the desktop it is running on does — `open-url!` above is
  ;; that, and it is why the connect screen opens a browser here now rather
  ;; than falling back to printing the URL for someone to copy.
  (platform/override! {:after! cosmic/after!
                       :every! cosmic/every!
                       :quit! cosmic/quit!
                       :open-url! open-url!
                       :screen-size cosmic/window-size
                       :pick-image! cosmic/pick-image!
                       :picked-image! cosmic/picked-image!
                       :clipboard-image-png! cosmic/clipboard-image-png!})
  (when-let [path (not-empty (System/getenv "FRQ_COSMIC_DUMP"))]
    (dump-tree-to! path))
  (app/start! {:after! cosmic/after!
               :every! cosmic/every!
               :title! cosmic-ffi/set-title!
               ;; The window's size, which frq lays its columns out against —
               ;; the message list is told how much room the people panel
               ;; leaves it.
               :measure! (fn []
                           (let [[w h] (cosmic/window-size)]
                             (when (and (pos? w) (not= w @s/window-width))
                               (reset! s/window-width w))
                             (when (and (pos? h) (not= h @s/window-height))
                               (reset! s/window-height h))))
               ;; Call frames are painted into a jvui texture, which is not here.
               :av? false})
  (ui/run app/app :title "frq" :width 520 :height 860))
