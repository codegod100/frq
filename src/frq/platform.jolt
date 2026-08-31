(ns frq.platform
  "The few things that are the platform's job rather than the app's."
  (:require [glimmer-vidya.core :as vidya]
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
    (vidya/open-url! (or url ""))
    (catch Exception _ false)))

(defn return-url
  "The link that brings the app back to the front once the browser is done, or
  nil where the browser never covered it. `frq://auth` is the manifest's own
  scheme; the activity is `singleTask`, so it is the running app that comes
  forward rather than a second copy of it."
  []
  (when (android?) "frq://auth"))
