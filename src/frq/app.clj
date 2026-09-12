(ns frq.app
  "frq — a freeq client, as glimmer components.

  The screens follow sleek's: connect, chats, chat, discover, settings, under a
  tab bar. Where sleek draws them in Rust against egui directly, here each is a
  hiccup component over glimmer's widget tags.

  No backend and no `-main`. This namespace is the screens and nothing else —
  which backend paints them is the entry point's business, and there is one
  entry point per backend: `frq.cosmic` for the window, `frq.tui` for the
  terminal. Each hands `start!` the timers and the window measurements its own
  loop can give."
  (:require [clojure.string :as str]
            [glimmer.ratom :as r :refer [atom]]
            [glimmer.core :as ui]
            [frq.av :as av]
            [frq.avatars :as avatars]
            [frq.clock :as clock]
            ;; For the side effect: this installs the desktop's answers to
            ;; `frq.io`, which everything under common/ asks its questions of.
            ;; Required here rather than in each -main because frq.tui and
            ;; frq.cosmic both come through frq.app, and the Flutter entry
            ;; point requires frq.io.dart instead and never loads this file.
            [frq.io.jolt]
            [frq.glyphs :as glyphs]
            [frq.media :as media]
            [frq.platform :as platform]
            [frq.profile.host :as profile]
            ;; The connect screen lives in common/ now — the same file the
            ;; phone renders. It reads frq.cells and calls frq.actions, and
            ;; this requires it exactly where its own copy used to be.
            [frq.actions :as actions]
            [frq.metrics :as metrics]
            [frq.screens.connect :as connect :refer [connect-screen error-note]]
            ;; The conversation list moved out too, with the tab bar and the
            ;; row it paints. Same arrangement as the connect screen: the
            ;; phone renders this very file.
            [frq.screens.chats :refer [below-list chats-screen conversation-row
                                       preview-line tab-bar]]
            [frq.screens.app :as screens]
            [frq.screens.settings :refer [discover-screen settings-screen
                                          tab-screen]]
            [frq.screens.chat :refer [chat-screen emoji-picker message-row
                                      reactor-dialog sidebar-width
                                      users-panel]]
            [frq.state :as s]))

;; ---------------------------------------------------------------- pieces

(def terminal? metrics/terminal?)

;; And whether that terminal draws pictures over its cells — Kitty's graphics
;; protocol, which kitty, Ghostty and WezTerm answer and an xterm does not.
;; `frq.tui` works it out from the environment and sets this beside the flag
;; above; a terminal that has not got it is the one described there, a column
;; of names with the words hanging under them.
(def terminal-graphics? metrics/terminal-graphics?)

(def ^:private terminal-face? metrics/terminal-face?)

(defonce ^:private derived-cells
  ;; One cell per question, kept for the session: a cell made afresh on every
  ;; render would add a watch to its source each time and never take it off.
  (clojure.core/atom {}))

(defn- derived
  "A reactive cell for one row's answer to a question about shared state, made
  once per `k` and kept.

  A message row that read `s/highlight` itself was re-rendered whenever the
  highlight moved anywhere — every row in the backlog, for one jump — and the
  same for a hover, an open picker, or any face or picture finishing a fetch.
  A reaction is recomputed on each such change, which is a comparison, but it
  wakes the rows that read it only when its answer changes: the two rows a
  jump moves between, the one face under the pointer.

  Kept rather than collected: glimmer's reactions have no way to unsubscribe,
  so a cell per message lasts as long as the session does."
  [k f]
  (or (get @derived-cells k)
      (let [cell (r/reaction (f))]
        (swap! derived-cells assoc k cell)
        cell)))

(defn- avatar-path
  "The cell answering where `actor`'s face is on disk, once it is."
  [actor]
  (derived [:avatar actor] #(do @s/media-tick (avatars/path-when-ready actor))))

(defn- image-path
  "The cell answering where the picture behind `url` is on disk, once it is."
  [url]
  (derived [:image url] #(do @s/media-tick (media/path-when-ready url))))

;; How big a face is on a message, in points — the size the window has always
;; drawn one at. A terminal's cell is eight points across and sixteen down, so
;; the same number is four columns by two rows there: a cached 128-pixel
;; portrait at a quarter size, and about the smallest a face is still a face at.
;; ---------------------------------------------------------------- chats

;; The way into a room. Standard rather than `:primary`: the theme paints a
;; suggested button as a filled lozenge, which is the highest-contrast fill it
;; has — and a filled lozenge on every card made the brightest, most regular
;; rhythm down the list the one word that is the same on every row, with the
;; name that differs set quieter than it. Nothing moves; the button stops
;; shouting.
(def ^:private window-row metrics/window-row)
;; Re-defined rather than moved out of reach: `frq.tui` resets this before its
;; first paint and says `app/chrome-row` when it does.
(def chrome-row metrics/chrome-row)

(def ^:private chrome-scale metrics/chrome-scale)

;; ---------------------------------------------------------------- chat

;; ---------------------------------------------------------------- split

;; ---------------------------------------------------------------- discover

;; ---------------------------------------------------------------- settings

;; ---------------------------------------------------------------- shell

(defn start!
  "Everything a launch does before the loop starts, for whichever backend is
  about to run it.

  This used to be the first half of `-main`, and a second entry point copied it
  — which is how frq.tui came up on a client that had restored nothing, was
  signed into nothing and was connected to nothing: an empty buffer with nobody
  in it, which reads as a broken screen rather than as a client that was never
  told to start.

  The timers are handed in because they belong to the backend: `after!` and
  `every!` are how anything gets onto the loop thread, and the terminal has its
  own pair. So are the two things only a window has — `title!` renames one, and
  `measure!` reports its size — and either may be nil where there is none.

  `av?` is the media plane. It wants a window: a call paints frames into a
  texture, and there is no texture in a terminal."
  [{:keys [after! every! title! measure! av?] :or {av? true}}]
  ;; Before the loop: the settings, the rooms this client has been in, and a
  ;; saved sign-in deciding which mode the connect screen opens in and what it
  ;; says.
  (s/restore-prefs!)
  (s/restore-channels!)
  (when (s/restore-session!)
    ;; And then it connects on its own. A remembered account has already said
    ;; what it wants; making it say so again at every launch is a click that
    ;; carries no information. It is a timer rather than a call here so the
    ;; screen is up first — the connect screen with its status is what the
    ;; user should be looking at while this happens, and if it fails, the
    ;; error lands somewhere visible.
    (after! 150 s/connect!))
  (when av?
    ;; Calls arrive rather than being asked for, so the media plane is drained
    ;; every frame whether or not one is up — the drain costs a single integer
    ;; read when it is not. It has to be a timer: `frame-rgba!` and everything
    ;; else that touches a node belongs to the loop thread, and this is
    ;; glimmer's way of getting onto it.
    (av/init-logging!)
    ;; Who to tell when a call ends under us rather than at our asking. Set
    ;; here rather than in frq.av because sending a TAGMSG needs the
    ;; connection, and that belongs to the state layer.
    (reset! av/on-dropped s/announce-leave!)
    (after! 0 av/install-pump!))
  ;; The surface's size, into a ratom, a few times a second. Polled rather than
  ;; delivered: the backend reports a size by writing it onto the window node,
  ;; and only what a component derefs re-renders — so the layout follows a drag
  ;; of the edge without every frame touching the tree.
  (when measure!
    (measure!)
    (every! 200 measure!))
  ;; The nick in the window title, so a second window of this client is told
  ;; apart from the first by the one thing that differs — and so the answer to
  ;; "who am I here?" is on screen without opening Settings.
  ;;
  ;; Polled, like the size above and for the same reason: the title belongs to
  ;; the window rather than to the tree, so no render puts it there, and the
  ;; nick is only settled once a connection has been made. Twice a second is
  ;; far more often than a nick changes, and a string compare is what a tick
  ;; costs when it has not.
  ;; Seeded with the title `run` opens the window under, so the first tick of
  ;; a launch that has nobody signed in yet sets nothing.
  (when title!
    (let [shown (atom "frq")]
      (every! 500 #(let [title (if (and (s/connected?) (seq @s/form-nick))
                                 (str "frq — " @s/form-nick)
                                 "frq")]
                     (when (not= title @shown)
                       (reset! shown title)
                       (title! title))))))
  nil)

;; Where a face or a picture is on disk, once it is. These stay here because
;; both are a glimmer reaction over a fetch-and-cache — `derived` is the one
;; place in this namespace that uses glimmer's own API — and a phone has
;; neither the reaction nor the cache. It installs nothing and the screens
;; draw what they draw before a face arrives.
;; The root, re-defined here: `frq.tui` and `frq.cosmic` both say `app/app`
;; when they mount, and the namespace they say it to is this one.
(def app screens/app)

(actions/install!
 ;; The value rather than the cell: a platform without a cache answers nil,
 ;; and `@nil` is not a thing. Derefing the reaction here keeps the desktop's
 ;; per-row waking, because the deref still happens inside the render.
 {:avatar-path (fn [actor] @(avatar-path actor))
  :image-path (fn [url] @(image-path url))
  ;; The profile half lives here rather than in frq.state, which does not
  ;; require frq.profile — whose card is open is a question about the screen,
  ;; not about the connection.
  :viewing (fn [] @profile/viewing)
  :profile-open! profile/open!
  :profile-close! profile/close!
  :profile-entry profile/entry
  :profile-stats-line profile/stats-line
  :profile-tick (fn [] @profile/tick)
  :profile-truncate profile/truncate
  :profile-web-url profile/web-url})
