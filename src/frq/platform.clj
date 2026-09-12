(ns frq.platform
  "The few things that are the platform's job rather than the app's."
  (:require [jolt.host :as host]))

(defn android?
  "Android, told from a desktop by a binary only it has. What hangs on this is
  which way the app and the browser sit: side by side, or one behind the other."
  []
  (host/file-exists? "/system/bin/am"))

(defonce ^:private desktop (delay (not (android?))))

(defn desktop?
  "True where there is a pointer to hover with, rather than a finger. Asked
  once per render of every row that has a face on it, so the answer is worked
  out once and kept — the question is a file that either exists or does not,
  and nothing about it changes while the app runs."
  []
  @desktop)

(defonce ^:private overrides
  ;; What the backend does. Filled in by the entry point that installs it —
  ;; `frq.cosmic`, `frq.tui` — before the app starts.
  ;;
  ;; This used to be a *diff* against glimmer-jvui: every key here fell back to
  ;; a jvui call, and a backend named only the ones it did differently. jvui is
  ;; gone, so there is no default backend to fall back to and the fallbacks
  ;; below are no-ops instead. That is the honest shape — the terminal has no
  ;; picture chooser and libcosmic has no video texture, and both used to get
  ;; one that quietly did nothing anyway.
  (atom {}))

(defn override!
  "Install what this backend does. Keys: :after! :every! :quit! :open-url!
  :pick-image! :picked-image! :clipboard-image-png! :screen-size :frame-rgba!
  :frame-drop!. Anything left out does nothing."
  [m]
  (swap! overrides merge m)
  nil)

(defn- op
  "The backend's answer for `k`, or `default` where it has none."
  [k default]
  (get @overrides k default))

(defn open-url!
  "Hand a URL to whatever shows web pages here. The backend knows what that
  means — xdg-open on a desktop, an ACTION_VIEW intent on Android, where no
  shelled-out `am start` is allowed to. False leaves the connect screen's
  \"if the browser did not open\" line to carry the URL across, which is what
  happens under a backend with no browser to hand it to."
  [url]
  (try
    ((op :open-url! (fn [_] false)) (or url ""))
    (catch Exception _ false)))

(defn after!
  "Run `f` on the UI thread in about `ms` milliseconds. jvui's timers only run
  inside jvui's loop, so a backend with a loop of its own has to lend its own."
  [ms f]
  ((op :after! (fn [_ _] nil)) ms f))

(defn quit!
  "Close the window."
  []
  ((op :quit! (fn [] nil))))

(defn pick-image!
  "Open the platform's picture chooser; true when there is one and it opened."
  []
  ((op :pick-image! (fn [] false))))

(defn picked-image!
  "Write the chosen picture to `path`; true once, when one has been chosen."
  [path]
  ((op :picked-image! (fn [_] nil)) path))

(defn clipboard-image-png!
  "Write the picture on the clipboard to `path` as PNG; true when there was one.
  jvui reads it through its own window, so another backend lends its own."
  [path]
  ((op :clipboard-image-png! (fn [_] false)) path))

(defn return-url
  "The link that brings the app back to the front once the browser is done, or
  nil where the browser never covered it. `frq://auth` is the manifest's own
  scheme; the activity is `singleTask`, so it is the running app that comes
  forward rather than a second copy of it."
  []
  (when (android?) "frq://auth"))

;; ------------------------------------------------------- the window itself

(defn every!
  "Run `f` on the UI thread every `ms` milliseconds. Returns a timer id where
  the backend has one to give."
  [ms f]
  ((op :every! (fn [_ _] nil)) ms f))

(defn screen-size
  "The window's content size as `[w h]`, or `[0 0]` under a backend with no
  window — which the callers already treat as \"do not lay anything out yet\"."
  []
  ((op :screen-size (fn [] [0 0]))))

;; --------------------------------------------------------------- video

;; Call frames are pixels pushed straight into a backend texture, never a jolt
;; value — see `frq.av/pump-frames!`. Only a backend with a GPU surface can
;; take them, so the default is to drop them on the floor, which is what
;; `:av? false` at the entry point already says in the other direction.

(defn frame-rgba!
  "Hand one decoded frame to the backend's texture for `key`."
  [key w h rgba]
  ((op :frame-rgba! (fn [_ _ _ _] nil)) key w h rgba))

(defn frame-drop!
  "Forget the texture for `key`."
  [key]
  ((op :frame-drop! (fn [_] nil)) key))
