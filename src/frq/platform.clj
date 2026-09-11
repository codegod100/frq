(ns frq.platform
  "The few things that are the platform's job rather than the app's."
  (:require [glimmer-jvui.core :as gui]
            [jolt.host :as host]))

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

(defn open-url!
  "Hand a URL to whatever shows web pages here. The backend knows what that
  means — xdg-open on a desktop, an ACTION_VIEW intent on Android, where no
  shelled-out `am start` is allowed to. False leaves the connect screen's
  \"if the browser did not open\" line to carry the URL across."
  [url]
  (try
    (gui/open-url! (or url ""))
    (catch Exception _ false)))

(defonce ^:private overrides
  ;; What a backend other than glimmer-jvui does in place of jvui's own. Filled
  ;; in by the entry point that installs that backend — `frq.cosmic` — before
  ;; the app starts; empty means the window's.
  (atom {}))

(defn override!
  "Replace some of what the platform does, for a backend other than jvui.
  Keys: :after! :quit! :pick-image! :picked-image!."
  [m]
  (swap! overrides merge m)
  nil)

(defn after!
  "Run `f` on the UI thread in about `ms` milliseconds. jvui's timers only run
  inside jvui's loop, so a backend with a loop of its own has to lend its own."
  [ms f]
  ((get @overrides :after! gui/after!) ms f))

(defn quit!
  "Close the window."
  []
  ((get @overrides :quit! gui/quit!)))

(defn pick-image!
  "Open the platform's picture chooser; true when there is one and it opened."
  []
  ((get @overrides :pick-image! gui/pick-image!)))

(defn picked-image!
  "Write the chosen picture to `path`; true once, when one has been chosen."
  [path]
  ((get @overrides :picked-image! gui/picked-image!) path))

(defn return-url
  "The link that brings the app back to the front once the browser is done, or
  nil where the browser never covered it. `frq://auth` is the manifest's own
  scheme; the activity is `singleTask`, so it is the running app that comes
  forward rather than a second copy of it."
  []
  (when (android?) "frq://auth"))
