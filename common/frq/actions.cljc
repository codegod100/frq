(ns frq.actions
  "What a screen can ask the app to do, named once so both can answer.

  The same shape as `frq.io`, one layer up: the cells in `frq.cells` are state
  a shared screen can read directly, and these are the things it cannot do for
  itself. `connect!` on the desktop is `frq.state/connect!` — IRC over jolt's
  TLS, SASL, the reader thread — and on the phone it is the dart:io one. The
  screen calls the same name either way and knows neither."
  (:refer-clojure :exclude [name]))

(defonce ^:private impl (atom {}))

(defn install!
  "Register what this platform does. Anything left out is a no-op, so a screen
  can be rendered before the action behind a button exists — which is how the
  phone got the connect screen on it before SASL was ported."
  [m]
  (swap! impl merge m)
  nil)

(defn- call [k args]
  (when-let [f (get @impl k)] (apply f args)))

(defn connected?
  "Whether there is a live connection. A query rather than a cell: what counts
  as connected is a socket, and each platform holds its own."
  []
  (boolean (call :connected? [])))

(defn connect! [] (call :connect! []))
(defn disconnect! [] (call :disconnect! []))
(defn forget-session! [] (call :forget-session! []))
(defn open-url! [url] (call :open-url! [url]))

;; ------------------------------------------------------------------ rooms

(defn join! [name] (call :join! [name]))
(defn open-channel! [name] (call :open-channel! [name]))
(defn leave-channel! [name] (call :leave-channel! [name]))

;; ------------------------------------------------------------------- chat
;;
;; The conversation screen's half. Commands where the screen asks for
;; something to happen, queries where it asks what is true — `wide?` is the
;; window's width and `member-count` is the server's answer, and neither is a
;; cell any screen could read for itself.

(defn send-draft! [] (call :send-draft! []))
(defn cancel-edit! [] (call :cancel-edit! []))
(defn cancel-reply! [] (call :cancel-reply! []))
(defn clear-attachment! [] (call :clear-attachment! []))
(defn open-image-picker! [] (call :open-image-picker! []))
(defn paste-image! [] (call :paste-image! []))
(defn jump-to-present! [] (call :jump-to-present! []))
(defn scrolled! [& args] (call :scrolled! args))
(defn toggle-users! [] (call :toggle-users! []))
(defn toggle-chat-list! [] (call :toggle-chat-list! []))
(defn toggle-overview! [] (call :toggle-overview! []))

(defn wide? [] (boolean (call :wide? [])))
(defn member-count [name] (call :member-count [name]))

;; ------------------------------------------------------------------ calls
;;
;; The media plane, which a phone has none of — `frq.av/available?` says so on
;; the desktop and nothing installs these here, so the call bar renders its
;; unavailable shape rather than being special-cased in the screen.

(defn start-call! [] (call :start-call! []))
(defn in-call? [] (boolean (call :in-call? [])))
(defn call-in [name] (call :call-in [name]))
(defn call-available? [] (boolean (call :call-available? [])))

;; ----------------------------------------------------------------- assets
;;
;; Where a face or a picture is on disk, once it is. Both are a fetch and a
;; cache on the desktop, behind a glimmer reaction so one arriving wakes only
;; the rows that read it; the phone has neither yet and answers nil, which the
;; screens already treat as "not here".

(defn avatar-path [actor] (call :avatar-path [actor]))
(defn image-path [url] (call :image-path [url]))

