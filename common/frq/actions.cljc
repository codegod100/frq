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
(defn member-count [& args] (call :member-count args))

;; ------------------------------------------------------------------ calls
;;
;; The media plane, which a phone has none of — `frq.av/available?` says so on
;; the desktop and nothing installs these here, so the call bar renders its
;; unavailable shape rather than being special-cased in the screen.

(defn start-call! [& args] (call :start-call! args))
(defn in-call? [& args] (boolean (call :in-call? args)))
(defn call-in [& args] (call :call-in args))
(defn call-available? [& args] (boolean (call :call-available? args)))

;; ----------------------------------------------------------------- assets
;;
;; Where a face or a picture is on disk, once it is. Both are a fetch and a
;; cache on the desktop, behind a glimmer reaction so one arriving wakes only
;; the rows that read it; the phone has neither yet and answers nil, which the
;; screens already treat as "not here".

(defn avatar-path [& args] (call :avatar-path args))
(defn image-path [& args] (call :image-path args))

;; ------------------------------------------------------- the rest of chat
;;
;; Reactions, the picker, jumping to a message, the overview and the two
;; dialogs. All of them reducers in `frq.state` on the desktop; a platform
;; that installs none of them gets a screen whose buttons do nothing rather
;; than a screen that will not draw.

(defn desktop? [] (boolean (call :desktop? [])))
(defn quit! [] (call :quit! []))
(defn hovering [] (call :hovering []))
(defn viewing [] (call :viewing []))
(defn accept-policy! [& args] (call :accept-policy! args))
(defn close-picker! [& args] (call :close-picker! args))
(defn hover-reaction! [& args] (call :hover-reaction! args))
(defn join-call! [& args] (call :join-call! args))
(defn leave-call! [& args] (call :leave-call! args))
(defn leaving-for-overview! [& args] (call :leaving-for-overview! args))
(defn member-list [& args] (call :member-list args))
(defn message-by-id [& args] (call :message-by-id args))
(defn mine? [& args] (call :mine? args))
(defn my-reaction? [& args] (call :my-reaction? args))
(defn open-dm! [& args] (call :open-dm! args))
(defn open-picker! [& args] (call :open-picker! args))
(defn overview-back! [& args] (call :overview-back! args))
(defn picker-emoji [& args] (call :picker-emoji args))
(defn react-from-picker! [& args] (call :react-from-picker! args))
(defn recent-everywhere [& args] (call :recent-everywhere args))
(defn reply-to! [& args] (call :reply-to! args))
(defn start-edit! [& args] (call :start-edit! args))
(defn toggle-reaction! [& args] (call :toggle-reaction! args))
(defn unhover-reaction! [& args] (call :unhover-reaction! args))

;; ------------------------------------------------------ the rest of a call
;;
;; The media plane's own state, which is not a cell here because it is not
;; state this app holds: it lives in `frq.av`, which wraps a MoQ session, the
;; codecs and the devices. A phone installs none of it.

(defn local-call [] (call :local-call []))
(defn local-feed [] (call :local-feed []))
(defn media-error [] (call :media-error []))
(defn tiles [& args] (call :tiles args))
(defn tile-rows [& args] (call :tile-rows args))
(defn set-muted! [& args] (call :set-muted! args))
(defn set-speaker-muted! [& args] (call :set-speaker-muted! args))
(defn set-camera! [& args] (call :set-camera! args))

;; --------------------------------------------------------------- platform

(defn after! [& args] (call :after! args))
(defn open-url! [& args] (call :open-url! args))

;; ---------------------------------------------------------------- profile

(defn profile-hover! [& args] (call :profile-hover! args))
(defn profile-unhover! [& args] (call :profile-unhover! args))
(defn profile-open! [& args] (call :profile-open! args))

