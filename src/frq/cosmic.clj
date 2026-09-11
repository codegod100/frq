(ns frq.cosmic
  "frq's own screens, painted by libcosmic.

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

    just cosmic"
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

(defn -main [& _]
  ;; What frq asks of glimmer-jvui directly, answered by this backend instead:
  ;; jvui's timers only run inside jvui's loop, its quit closes jvui's window,
  ;; and it has no picture chooser on a desktop.
  (platform/override! {:after! cosmic/after!
                       :quit! cosmic/quit!
                       :pick-image! cosmic/pick-image!
                       :picked-image! cosmic/picked-image!})
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
