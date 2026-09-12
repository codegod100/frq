(ns frq.cells
  "The cells the connect screen reads, and the constants beside them.

  Moved out of `frq.state` so a screen can be shared: `frq.state` is 1,930
  lines that reach `frq.irc` and `frq.av` and will not compile under
  ClojureDart for a long time yet, but the cells themselves are atoms and
  atoms are portable. `frq.state` re-defs every name here, so its own thousand
  lines did not move and neither did anything reading `s/form-handle`.

  The reader conditional is the whole trick. On jolt these are glimmer ratoms
  — a component that derefs one re-renders when it changes, which is what the
  desktop's reconciler is built on. Under ClojureDart they are ordinary atoms,
  and `cljd.flutter`'s `:watch` does the same job from the other end. Neither
  compiler sees the other's require.

  jolt answers to `:jolt` and ClojureDart to `:cljd`; ClojureDart also has
  `:clj` always on, which is why neither branch is spelled that way."
  (:require #?@(:cljd []
                :jolt [[glimmer.ratom :refer [atom]]])))

(def default-host "irc.freeq.at")
(def default-port "6697")

;; screen: :connect | :chats | :chat | :discover | :settings
(defonce screen (atom :connect))
(defonce status (atom "Not connected"))
(defonce error (atom nil))
(defonce connecting? (atom false))

(defonce form-host (atom default-host))
(defonce form-port (atom default-port))
;; TLS is the default; untick it for a server's plain :6667 listener
(defonce form-tls? (atom true))
(defonce form-nick (atom "frq-guest"))

;; Bluesky sign-in. The app password reaches the user's own PDS and nothing
;; else: freeq is handed the session token it mints, and verifies that token by
;; asking the same PDS. It is never written to disk.
(defonce auth-mode (atom :guest))         ; :guest | :bluesky | :app-password
(defonce form-handle (atom ""))
(defonce form-app-password (atom ""))
(defonce session (atom nil))              ; a pds-session or a web-token one

;; The durable half of an OAuth sign-in. The web-token beside it is single-use,
;; so a reconnect mints a fresh one from this rather than replaying the old.
; ------------------------------------------------------------------ rooms
;; name -> {:name :messages [{:from :text}] :unread n :joined? bool}
(defonce channels (atom {}))
(defonce current (atom nil))
(defonce join-input (atom ""))
(defonce search (atom ""))

(defonce broker-token (atom nil))
(defonce login-url (atom nil))            ; shown while the browser is open
