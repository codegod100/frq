(ns frq.app
  "frq — a freeq client written as glimmer components, painted by Vidya/egui.

  The screens follow sleek's: connect, chats, chat, discover, settings, under a
  tab bar. Where sleek draws them in Rust against egui directly, here each is a
  hiccup component over the same widgets."
  (:require [clojure.string :as str]
            [glimmer.ratom :as r :refer [atom]]
            [glimmer.core :as ui]
            [glimmer-jvui.core :as gui]
            [frq.av :as av]
            [frq.avatars :as avatars]
            [frq.clock :as clock]
            [frq.glyphs :as glyphs]
            [frq.media :as media]
            [frq.platform :as platform]
            [frq.profile :as profile]
            [frq.state :as s]))

;; ---------------------------------------------------------------- pieces

(defn error-note
  "Always a node, never nil.

  A conditional child that disappears shifts every sibling after it, and the
  reconciler matches children by position — so an error appearing mid-screen
  would patch the header into a card. A stable wrapper with a stable key keeps
  the shape of the tree fixed and only its contents changing."
  []
  [:vbox {:key :error-note :spacing 6}
   (when-let [e @s/error]
     [:card {}
      [:label {:label (str "⚠ " e)}]
      [:button {:label "Dismiss" :on-click #(reset! s/error nil)}]])])

(defn tab-bar []
  [:hbox {:spacing 8}
   (for [[k label] [[:chats "Chats"] [:discover "Discover"] [:settings "Settings"]]]
     [:button {:key k
               :label label
               :kind (if (= k @s/screen) :primary :default)
               :on-click #(reset! s/screen k)}])])

;; ---------------------------------------------------------------- connect

(defn- mode-tabs []
  [:hbox {:spacing 8}
   (for [[k label] [[:guest "Guest"] [:bluesky "Bluesky"] [:app-password "App password"]]]
     [:button {:key k
               :label label
               :kind (if (= k @s/auth-mode) :primary :default)
               :on-click #(reset! s/auth-mode k)}])])

(defn- server-fields []
  [:vbox {:spacing 6}
   [:label {:label "Server"}]
   [:hbox {:spacing 8}
    [:entry {:text @s/form-host
             :width-request 220
             :placeholder "host"
             :on-change #(reset! s/form-host %)}]
    [:entry {:text @s/form-port
             :width-request 90
             :placeholder "6697"
             :on-change #(reset! s/form-port %)}]]
   [:checkbutton {:label "TLS"
                  :active @s/form-tls?
                  :on-toggled #(do (swap! s/form-tls? not)
                                   (reset! s/form-port
                                           (if @s/form-tls? "6697" "6667")))}]])

(defn- connect-action []
  (if @s/connecting?
    [:hbox {:spacing 8}
     [:spinner {}]
     [:dim-label {:label @s/status}]]
    [:hbox {:spacing 8}
     [:button {:label "Connect" :kind :primary :on-click s/connect!}]
     [:dim-label {:label @s/status}]]))

(defn connect-screen []
  [:page {:max-width 520}
   [:title {:label "frq"}]
   [:dim-label {:label "freeq client — guest, or your Bluesky identity."}]
   [error-note]
   [:card {}
    [mode-tabs]
    (case @s/auth-mode
      :bluesky
      [:vbox {:spacing 6}
       [:title-2 {:label "Sign in with Bluesky"}]
       [:dim-label {:label "Opens your browser for AT Protocol OAuth. freeq's broker hands back a token; no password passes through frq."}]
       [:label {:label "Handle"}]
       [:entry {:text @s/form-handle
                :width-request 320
                :placeholder "alice.bsky.social"
                :on-change #(reset! s/form-handle %)}]
       [:vbox {:key :remembered :spacing 4}
        (when @s/broker-token
          [:vbox {:spacing 4}
           [:dim-label {:label "Session remembered — Connect will not need the browser."}]
           [:button {:label "Forget saved session" :on-click s/forget-session!}]])]
       [:vbox {:key :login-url :spacing 4}
        (when-let [url @s/login-url]
          [:vbox {:spacing 4}
           [:dim-label {:label "If the browser did not open, visit:"}]
           [:label {:label url}]])]]

      :app-password
      [:vbox {:spacing 6}
       [:title-2 {:label "Sign in with an app password"}]
       [:dim-label {:label "No browser. Your app password goes to your own PDS; freeq is handed the session it mints."}]
       [:label {:label "Handle"}]
       [:entry {:text @s/form-handle
                :width-request 320
                :placeholder "alice.bsky.social"
                :on-change #(reset! s/form-handle %)}]
       [:label {:label "App password"}]
       [:entry {:text @s/form-app-password
                :width-request 320
                :placeholder "xxxx-xxxx-xxxx-xxxx"
                :on-change #(reset! s/form-app-password %)}]
       [:dim-label {:label "Make one at bsky.app → Settings → App Passwords."}]]

      [:vbox {:spacing 6}
       [:title-2 {:label "Connect as guest"}]
       [:label {:label "Nick"}]
       [:entry {:text @s/form-nick
                :width-request 320
                :placeholder "your nick"
                :on-change #(reset! s/form-nick %)}]])
    [server-fields]
    [:separator {}]
    [connect-action]]
   [:dim-label {:label "TLS rides jolt's OpenSSL bindings; untick it for a plain :6667 listener. Sign-in needs TLS, so it is desktop-only."}]])

;; Whether the backend under this tree is a terminal, set by `frq.tui` before
;; the first paint and never again. Two things in a message hang on it, and
;; both are about a cell grid rather than a canvas: there is no picture to
;; draw a face with, and a name with nothing to its left is the heading the
;; text hangs off — the shape a terminal has read messages in for forty years.
(defonce terminal? (atom false))

;; And whether that terminal draws pictures over its cells — Kitty's graphics
;; protocol, which kitty, Ghostty and WezTerm answer and an xterm does not.
;; `frq.tui` works it out from the environment and sets this beside the flag
;; above; a terminal that has not got it is the one described there, a column
;; of names with the words hanging under them.
(defonce terminal-graphics? (atom false))

(defn- terminal-face?
  "Whether a message carries a picture of its sender in a terminal.

  Not the same question as `terminal?`: the face is drawn where the protocol
  for one is, and where it is not an `:image` is `[ picture ]` printed beside
  every nick — worse than the nothing that is there now."
  []
  (and @terminal? @terminal-graphics?))

;; How big a face is on a message, in points — the size the window has always
;; drawn one at. A terminal's cell is eight points across and sixteen down, so
;; the same number is four columns by two rows there: a cached 128-pixel
;; portrait at a quarter size, and about the smallest a face is still a face at.
(def ^:private face-size 32)

;; ---------------------------------------------------------------- chats

(defn- open-button [name]
  [:button {:label "Open"
            :kind :primary
            :on-click #(s/open-channel! name)}])

;; The only way out of a room. Everything else adds one — the server saying we
;; are in it, a message arriving in it — so without this the list only grows,
;; and what rooms.edn claims we are in could never shrink.
(defn- close-button [name]
  [:button {:label "Close"
            :on-click #(s/leave-channel! name)}])

(defn conversation-row [buffer]
  (let [name (:name buffer)
        ;; Defaulted rather than assumed. Everything that builds a buffer
        ;; goes through `ensure-channel`, but the list draws whatever is in
        ;; the atom, and a half-made room reaching here should be a row that
        ;; reads as quiet rather than the frame that killed the client.
        unread (:unread buffer 0)]
    [:card {:key name}
     ;; The name gets the line, and membership and unread count the one under
     ;; it. All three on one line is what the list pane has no room for: the
     ;; name takes what it likes, the badges are left the remainder, and a
     ;; long name squeezes them into a status reading "joine/d" and a count
     ;; split down two lines — while the card, sized to a row that no longer
     ;; fits, sticks out past the cards above and below it.
     ;;
     ;; In a terminal the Open button rides up onto the name's line. A row of
     ;; chrome there is one cell, so a button on a line of its own costs the
     ;; card a whole row — four of them and the list has spent a screenful on
     ;; buttons. A window's row is 34 points and its button is a lozenge with
     ;; air around it, which is why it keeps its own line there.
     (if @terminal?
       [:hbox {:spacing 8 :wrap false}
        [:title-2 {:label name}]
        [open-button name]
        [close-button name]]
       [:title-2 {:label name}])
     ;; `:wrap false` on the badges: they sit beside each other or not at all.
     [:hbox {:spacing 12 :wrap false}
      ;; A DM has no membership to report — there is nothing to be in — so the
      ;; badge says what the buffer is instead of answering a question nobody
      ;; asked of it.
      [:status {:label (cond (s/dm? name) "direct message"
                             (:joined? buffer) "joined"
                             :else "not joined")
                :live (boolean (:joined? buffer))}]
      ;; A mention is not more unread, it is different unread: the dot says
      ;; how much there is and the name says it was aimed at you. Both or
      ;; neither — a room with your name in it always has a line to count.
      (when (pos? unread)
        [:label {:label (str (if (:mention? buffer) "◆ @ " "● ") unread)}])]
     [:dim-label {:label (s/last-preview buffer)}]
     (when-not @terminal?
       [:hbox {:spacing 8 :wrap false}
        [open-button name]
        [close-button name]])]))

(def ^:private sidebar-width 320)

;; How tall a row of chrome is — a button, the compose bar, a line of tabs.
;;
;; The two reserves below are counted in points against this: a window's row is
;; 34 of them, and every gap around it was chosen at that size. A terminal's
;; row is one cell, and the same count then reserves two or three times the
;; room the strip under the list actually needs — which costs a message a row,
;; and a conversation is measured in how many of those fit.
;;
;; So the counts stay as they are, written where the reasoning is, and a
;; backend whose rows are a different height says so here. Nothing else in the
;; tree needs it: every other number is a length, and a length scales on the
;; way across.
(def ^:private window-row 34)
(defonce chrome-row (atom window-row))

(defn- chrome-scale [] (/ (double @chrome-row) window-row))

(defn- chip-gap
  "The air between two chips on a row.

  Four points is half a column, which rounds to none: in a window that is the
  gap a pair of lozenges want, and in a terminal it puts two emoji hard against
  each other and they read as one wide glyph. A column, where a column is the
  smallest thing there is."
  []
  (if @terminal? 8 4))

(defn- indented
  "One of a message's columns, held in from the name above it — in a terminal.

  The nick is the heading and the words hang under it, which is the shape a
  terminal has read a conversation in for forty years; in a window the column
  of faces already marks that edge, so there is nothing to hold in.

  A cell of its own rather than a margin, because the backend insets a node by
  `:margin` on all four sides or not at all: there is no left margin in a cell
  grid, and a uniform one would spend a blank row above every message to buy
  two columns beside it.

  The spacer asks for its width and no height. A `:size` is a length down the
  page, and a spacer two cells tall beside an empty column — a message with no
  picture and no reactions — is two blank rows in the middle of the backlog,
  which is a message and a half at this size.

  Nothing to do where a face is drawn: the column that holds the portrait is
  already to the left of the whole message, and a second indent inside it would
  hold the words in from a name that is itself held in."
  [k node]
  (if (and @terminal? (not (terminal-face?)))
    [:hbox {:key k :spacing 0}
     [:spacer {:key :indent :size 0 :width-request 16}]
     node]
    node))

(defn- below-list []
  ;; What the strip under the list needs, counted: the gap after the list, the
  ;; separator, the gap under it, the tab bar's row of buttons and the margin
  ;; below them. Short by any of it and the tabs go off the bottom edge — which
  ;; is the thing this layout exists to stop.
  (* (chrome-scale) (+ 8 8 8 34 12)))

(defn chats-screen []
  (let [buffers (s/channel-list)]
    ;; Three bands rather than a page: the title and the two boxes at the top,
    ;; the tabs at the bottom, and the conversations scrolling between them.
    ;; Everything you act with stays where you last saw it — the same bargain
    ;; the chat screen makes, where the compose bar holds still under a backlog
    ;; that moves.
    ;;
    ;; What goes with the page is its centring at 620, on a window between that
    ;; and the split view's 900: the list is full-bleed there now, which is
    ;; what the conversation beside it has always been.
    ;; `:fill-height` on the outermost box, not only on the band inside it.
    ;; A backend that gives a column the height of what is in it hands the
    ;; band below a window's worth of nothing to divide: the list asks for
    ;; the rest of the screen, is told the rest is forty points, and the
    ;; whole screen paints into a strip along the top with the window empty
    ;; under it. Every screen that pins something to the bottom says this on
    ;; its own root — the split view already said it, one wrapper further out.
    [:vbox {:spacing 8 :margin 12 :fill-height true}
     [:vbox {:key :head :spacing 8}
       ;; Your nick in the title, where "Chats" alone said nothing you did not
      ;; already know. It is what every channel calls you and what your own
      ;; lines are signed with, and the only other place it showed was Settings.
      [:title {:label (if (s/connected?) (str "Chats as " @s/form-nick) "Chats")}]
      [error-note]
      ;; Join and search are the same shape — a channel box with a button
      ;; beside it — so they read as one control block rather than a titled
      ;; card and a stray row: same card, same widths, same gap. The screen
      ;; title already says what the box is for, which is what the "Join
      ;; channel" header was doing.
      [:card {}
       [:vbox {:spacing 8}
        ;; Button first and `:align :end`, so the row is laid out from its
        ;; right edge: the button is placed against that edge and the box takes
        ;; what is left. An entry asks for whatever remains where it stands, so
        ;; a box placed first takes the row and pushes the button onto a line of
        ;; its own — Join under the box rather than beside it — and a box given
        ;; a fixed width only holds that off until the window is narrower than
        ;; the number. Laid out from the right the box is the part that gives,
        ;; at every width, in the frame the drag happens rather than the one
        ;; after the window is next measured.
        [:hbox {:spacing 8 :align :end}
         [:button {:label (if (str/starts-with? @s/join-input "@") "Message" "Join")
                   :kind :primary
                   :on-click #(do (s/join! @s/join-input) (reset! s/join-input ""))}]
         ;; Both kinds of conversation through one box: `#room` joins a
         ;; channel, `@nick` opens a message to a person.
         [:entry {:text @s/join-input
                  :placeholder "#channel or @nick"
                  :on-change #(reset! s/join-input %)
                  :on-activate #(do (s/join! @s/join-input) (reset! s/join-input ""))}]]
        ;; The clear button only shows while there is something to clear: an
        ;; empty box has nothing to undo, and a dead button beside it reads as
        ;; one that stopped working. It leads the row for the same reason the
        ;; Join button does, and the box gives up the width it takes.
        [:hbox {:spacing 8 :align :end}
         (when (seq @s/search)
           [:button {:label "✕" :on-click #(reset! s/search "")}])
         [:entry {:text @s/search
                  :placeholder "Search channels"
                  :on-change #(reset! s/search %)}]]]]]
     ;; `:fill-height` so the scroll inside is handed the rest of the window
     ;; rather than the one card it starts out holding, and `:reserve` to keep
     ;; the tabs' strip out of what it may take.
     ;; Named, so it is the same list — and the same scroll position — when the
     ;; reader comes back from a conversation.
     [:vbox {:key :list :fill-height true}
      [:scroll {:scroll-key "chats-list" :orientation :vertical
                :reserve (below-list)}
       (if (seq buffers)
         ;; Keyed on the name, because this list reorders: opening a
         ;; conversation bumps it to the top, and unkeyed children reconcile by
         ;; position — the widgets stay put and their props are rewritten under
         ;; them. What is focused is a widget, so the highlight would stay in
         ;; the slot the reader clicked while the row that moved into it is
         ;; someone else's conversation.
         (for [b buffers] ^{:key (:name b)} [conversation-row b])
         [:card {} [:dim-label {:label "No conversations yet — join a channel."}]])]]
     [:vbox {:key :foot :spacing 8}
      [:separator {}]
      [tab-bar]]]))

;; ---------------------------------------------------------------- chat

(def ^:private url-pattern #"https?://[^\s<>\"]+")

(defn- trim-trailing-punctuation
  "A URL at the end of a sentence would otherwise keep the sentence's
  punctuation. A closing bracket only counts as trailing when the URL does not
  open one itself, which is what keeps a wikipedia-style path intact."
  [url]
  (loop [u url]
    (let [c (last u)]
      (cond
        (nil? c) u
        (contains? #{\. \, \; \: \! \?} c) (recur (subs u 0 (dec (count u))))
        (and (= \) c) (not (str/includes? u "("))) (recur (subs u 0 (dec (count u))))
        :else u))))

(defn text-runs
  "Message text as alternating [:text s] and [:link url] runs.

  Runs because a link has to be its own widget to be clickable, and stacked
  rather than laid out in a row because a wrapping label inside a horizontal
  row lays out against the row's width, not the column's — which is what drags
  long URLs off the left edge."
  [text]
  (let [text (or text "")]
    (loop [pos 0 acc []]
      (if-let [raw (re-find url-pattern (subs text pos))]
        (let [url (trim-trailing-punctuation raw)
              at (+ pos (str/index-of (subs text pos) raw))
              before (subs text pos at)
              acc (cond-> acc (seq before) (conj [:text before]))]
          (recur (+ at (count url)) (conj acc [:link url])))
        (let [tail (subs text pos)]
          (cond-> acc (seq tail) (conj [:text tail])))))))

(def ^:private text-emoji-size
  "An emoji in a message, at the size of the words around it. Bigger and the
  line it sits in grows to make room for it; smaller and it reads as a
  footnote on the sentence rather than a word of it."
  14)

(defn- word-node
  "Body text, or dim text for the lines the client writes itself."
  [k value system?]
  (if system?
    [:dim-label {:key k :label value}]
    [:label {:key k :label value}]))

(defn- run-node
  "One run as a widget. A link is accent-coloured and opens on click; the rest
  is body text.

  Except for the emoji in it. A label is set in the text font, and that font —
  Ubuntu with a DejaVu subset behind it — has no emoji in it at all, so every
  one anybody typed was drawn as tofu. The Twemoji pack has the picture, so
  the emoji come out of the text and are drawn from the pack, and the words
  either side stay text.

  `:emoji` and not `:reaction`, though both draw the same picture. A reaction
  is a tally: it wears a pill, it answers the pointer, and it names the people
  in it on hover. An emoji in a sentence is a character — so it is drawn bare,
  and a message that ends in one no longer reads as a message someone has
  reacted to.

  The pieces go in a wrapping row rather than the column the runs themselves
  are stacked in: a row is what puts an emoji *in* a sentence instead of
  breaking the sentence around it, and `:hbox` wraps its children by default,
  so a long line still folds at the column's edge. A run with no emoji in it
  is still one plain label — the row is only paid for where it is needed."
  [j [kind value] system?]
  (if (= :link kind)
    [:link {:key j :label value :on-click #(platform/open-url! value)}]
    (let [pieces (glyphs/runs (str/trim value))]
      (if (glyphs/emoji? pieces)
        ;; Runs alternate text and picture, so this gap only ever falls either
        ;; side of an emoji — never between two words, whose spacing is the
        ;; spaces the message was typed with. A bare glyph carries no margin of
        ;; its own the way the pill did, and a picture set flush against a word
        ;; reads as part of it.
        [:hbox {:key j :spacing 2}
         (map-indexed (fn [k [pkind pvalue]]
                        (if (= :emoji pkind)
                          [:emoji {:key k :emoji pvalue :size text-emoji-size}]
                          (word-node k pvalue system?)))
                      pieces)]
        (word-node j (str/trim value) system?)))))

(defn- summarise
  "A message in one line's worth of words."
  [m limit]
  (let [text (str/replace (or (:text m) "") #"\s+" " ")]
    (if (> (count text) limit)
      (str (subs text 0 (dec limit)) "…")
      text)))

(defn- reply-chip
  "What a message is replying to, above it, and a way back to it.

  The chip carries the quote rather than only a marker: a reply is unreadable
  without knowing what it answers, and the message it answers is usually off
  the top of the screen. Clicking takes you there."
  [channel id]
  [:vbox {:key :reply}
   (if-let [target (s/message-by-id channel id)]
     ;; A link, not a button: the chip is a pointer back to a line, not an
     ;; action, and a filled pill above every answer was the loudest thing in
     ;; the column.
     [:link {:label (str "↩ " (:from target) ": " (summarise target 48))
             :on-click #(do (reset! s/jump-to id)
                            (reset! s/highlight id)
                            ;; Off again once the frame that scrolled has
                            ;; been painted, so the reader keeps the view.
                            (gui/after! 120 (fn [] (reset! s/jump-to nil)))
                            ;; The highlight stays long enough to be read,
                            ;; and only clears itself: a later jump elsewhere
                            ;; owns the highlight from then on.
                            (gui/after! 2000
                                          (fn []
                                            (when (= id @s/highlight)
                                              (reset! s/highlight nil)))))}]
     ;; The message it answers is older than this buffer goes.
     [:dim-label {:label "↩ replying to an earlier message"}])])

(def ^:private pill-size
  "How big a reaction is under a message. Small: it is a footnote on what was
  said, not a second thing said."
  14)

(defn- action-chips
  "Answering and reacting, on the sender's row above the message.

  Both are things done *to* a message rather than parts of it, so they ride
  the sender's row against its right edge, at the size a reaction is. In the
  line with the text they took width off every line under them and wrapped a
  message that had the room to sit on one.

  Chips rather than buttons: a button is sized for a label and these carry a
  glyph, which made two lozenges taller than the line they belonged to.
  `:reaction` with no count is the same pill the picker offers, so what you
  press to react and what appears once you have look like one family.

  A row laid out from the right lays its first child furthest right, so
  reacting comes first in the source and this reads ✏️ then ↩️ then 🙂 on
  screen — where there is a pencil at all. Only our own lines carry one: the
  server refuses an edit of somebody else's, and a chip that always fails is a
  chip that lies about what can be done.

  The pencil is a chip beside the other two rather than a box holding one: a
  wrapper is laid out as a child in its own right, which put the pencil on the
  row at a remove from the pair it belongs with. It keys itself, so the line
  that has no pencil is a row of two chips and not a row with a hole in it."
  [channel m]
  (into [:hbox {:key :actions :align :end :spacing (chip-gap)}
         [:reaction {:key :react
                     :emoji "🙂"
                     :size pill-size
                     :on-click #(s/open-picker! channel m)}]
         [:reaction {:key :reply
                     :emoji "↩️"
                     :size pill-size
                     :on-click #(s/reply-to! m)}]]
        (when (s/mine? m)
          [[:reaction {:key :edit
                       :emoji "✏️"
                       :size pill-size
                       :on-click #(s/start-edit! channel m)}]])))

(defn- reactor-card
  "Who is on a reaction, beside the pointer resting on it.

  The pill carries a number, and a number is the one thing about a reaction
  nobody wants: who it was is what a room is read for. Names, one to a line,
  with your own said as \"you\" — you are the one name in the list you cannot
  learn anything from."
  [emoji nicks]
  [:vbox {:spacing 4}
   [:hbox {:spacing 6}
    [:reaction {:key :glyph :emoji emoji :size pill-size}]
    [:dim-label {:label (str (count nicks)
                             (if (= 1 (count nicks)) " reaction" " reactions"))}]]
   [:vbox {:key :who :spacing 2}
    (for [nick (sort nicks)]
      [:label {:key nick
               :label (if (= nick @s/form-nick) "you" nick)}])]])

(defn- reaction-row
  "What people have put on a message, under it.

  A pill carries its count and toggles: clicking one you are already on takes
  yours off, which is the same gesture that put it there. `:reaction` rather
  than a button with the emoji as its label — the chip draws the glyph from the
  Twemoji pack, in colour, where a label gets whatever the text font has."
  [channel m]
  (let [reactions (:reactions m)]
    [:hbox {:key :pills :spacing (chip-gap)}
     (for [emoji (sort (keys reactions))]
       [:reaction (cond-> {:key emoji
                           :emoji emoji
                           :size pill-size
                           :count (count (get reactions emoji))
                           :mine (s/my-reaction? m emoji)
                           :on-click #(s/toggle-reaction! channel m emoji)}
                    ;; Where there is a pointer to ask with, resting on a pill
                    ;; says who put it there. On a phone the pill is a button
                    ;; and nothing more: there is no hover to answer.
                    (platform/desktop?)
                    (assoc :on-hover #(s/hover-reaction! (:id m) emoji)
                           :on-unhover #(s/unhover-reaction! (:id m) emoji)))
        ;; Only the hovered pill carries a card: the panel is painted from
        ;; whatever children the node has, and a channel's worth of unseen
        ;; lists is a tree nobody looks at.
        (when (and (platform/desktop?) (s/hovering-reaction? (:id m) emoji))
          [reactor-card emoji (get reactions emoji)])])]))

(def ^:private picker-columns
  "Emoji to a row, at the picker's own size. Narrow enough that the grid fits a
  phone-width window, which is the width this app is laid out for."
  9)

(def ^:private picker-size 20)

;; A row of chips, and the most the grid may take before it scrolls.


(defn emoji-picker
  "The whole set to choose from, under the message it is for.

  It opens in the list itself, directly under the line it was opened on:
  choosing a reaction is something done *to* a message, and the message has to
  stay in front of the reader while it is chosen — which is not something a
  panel at the bottom of the window, or a screen of its own, can promise.

  It opens on the emoji people actually react with; the groups and the search
  box are for the rest."
  []
  (let [shown (s/picker-emoji)
        over (max 0 (- (count shown) s/picker-limit))
        rows (partition-all picker-columns (take s/picker-limit shown))
        searching? (seq (str/trim @s/emoji-search))]
    [:vbox {:key :picker :spacing 4}
     [:hbox {:spacing 6}
      [:entry {:text @s/emoji-search
               :width-request 240
               :placeholder "Search emoji"
               :on-change #(reset! s/emoji-search %)}]
      [:button {:label "✕" :on-click s/close-picker!}]]
     ;; The groups are what the search box is not: a way in for someone who has
     ;; no word for what they want. Their first word is enough to tell them
     ;; apart, and is what keeps them to two rows. They give way to the
     ;; search's own answer while something is typed.
     [:vbox {:key :groups :spacing 4}
      (when-not searching?
        (for [[i row] (map-indexed vector (partition-all 5 (cons nil s/emoji-groups)))]
          [:hbox {:key i :spacing 4}
           (for [g row]
             [:button {:key (or g "popular")
                       :label (if g (first (str/split g #" ")) "Popular")
                       :kind (if (= g @s/emoji-group) :primary :normal)
                       :on-click #(reset! s/emoji-group g)}])]))]
     ;; The grid itself, not a scroll around it: the picker sits inside the
     ;; message list, and a scroll within a scroll takes the wheel away from
     ;; the conversation it is standing in. What it shows is bounded instead,
     ;; and the search box is how you reach past that.
     [:vbox {:key :grid :spacing 2}
      (if (seq rows)
        (for [[i row] (map-indexed vector rows)]
          [:hbox {:key i :spacing 2}
           (for [[glyph] row]
             [:reaction {:key glyph
                         :emoji glyph
                         :size picker-size
                         :count 0
                         :on-click #(s/react-from-picker! glyph)}])])
        [:dim-label {:label "No emoji by that name."}])]
     ;; What was left out, said rather than silently dropped.
     [:vbox {:key :more}
      (when (pos? over)
        [:dim-label {:label (str "and " over " more — keep typing to narrow it")}])]]))

(defn hover-card
  "Who someone is, in the few lines that fit beside a pointer.

  The profile screen's opening, without the ways onward: a picture, the name
  they go by, their handle, and the first of their bio. What it cannot say yet
  it says plainly — a fetch in flight, a guest with no identity to look up —
  because a card that is blank while it waits reads as a card with nothing on
  it."
  [nick actor]
  (let [_ @profile/tick
        _ @s/media-tick
        pr (profile/entry actor)
        ready? (= :ready (:status pr))
        display (or (:display-name pr) nick)]
    [:vbox {:spacing 6}
     [:hbox {:spacing 10}
      [:avatar {:label nick
                :src (or (avatars/path-when-ready actor) "")
                :size 48}]
      [:vbox {:spacing 2}
       [:title-2 {:label display}]
       [:vbox {:key :nick}
        (when (not= display nick) [:dim-label {:label nick}])]
       [:vbox {:key :handle}
        (when-let [h (and ready? (not-empty (or (:handle pr) "")))]
          [:label {:label (str "@" h)}])]]]
     ;; Shorter than the screen's: this is a glance, not a read, and a bio
     ;; that fills the window beside a pointer is in the way of the chat.
     [:vbox {:key :bio :spacing 2}
      (when-let [bio (and ready? (:description pr))]
        (for [[i line] (map-indexed vector (str/split-lines (profile/truncate bio 200)))]
          [:label {:key i :label line}]))]
     [:vbox {:key :stats}
      (when-let [line (and ready? (profile/stats-line pr))]
        [:dim-label {:label line}])]
     [:vbox {:key :status}
      (cond
        (nil? actor) [:dim-label {:label "Guest — no Bluesky identity"}]
        (= :loading (:status pr)) [:dim-label {:label "Loading…"}]
        (= :failed (:status pr)) [:dim-label {:label "No Bluesky profile found"}])]
     [:dim-label {:label "Click for the full profile"}]]))

(defn- preview-height
  "How tall a picture in the conversation may be.

  Against the window rather than a fixed 260: on a phone-sized window a
  preview that tall is the whole screen, and on a laptop one it is a stamp of
  something worth looking at.

  Four fifths of the window, because the pictures that arrive here are mostly
  phone screenshots — 1080x2400, whose height is what binds, and any smaller
  share draws them as a strip too narrow to read a word of. A picture is what
  the message is; the line above it is enough context to place it, and the
  scroll is how the rest is reached.

  Clamped at both ends, and falling back to the old fixed height until the
  first poll has landed: a preview is a preview either way, and the lightbox
  is what full size is for.

  A terminal gets less of its screen, and a hard ceiling on top of that. Four
  fifths of a window is a picture you look at; four fifths of a terminal is a
  conversation with one message in it, and the rows a picture takes are rows
  that cannot hold a line. Twelve of them is enough to see what a picture is
  of, and to decide whether to open it."
  []
  (let [h @s/window-height]
    (cond
      (not (pos? h)) 260
      @terminal? (max 80 (min 192 (long (* 0.4 h))))
      :else (min 900 (max 240 (long (* 0.8 h)))))))

(defn- preview-width
  "How wide a picture in the conversation may be.

  The height alone leaves a wide, short picture to take the column and push
  the words around it; this holds it inside the conversation the same way.
  Fitted, never stretched — `:image` scales to whichever bound it meets first."
  []
  (let [w @s/window-width]
    (if (pos? w) (min 900 (max 240 (long (* 0.95 w)))) 320)))

(defn- message-body
  "A message without its face: the sender's line, the words, and what hangs
  under them.

  Its own component because a terminal that draws pictures puts the face
  beside all of this rather than on the sender's line — the shape the window
  has always had, and the one that spends no row on the half of a portrait
  that is taller than a line of text."
  [m highlit?]
  ;; A key each: the surface a jump leaves behind is a different node from the
  ;; plain column, not the same node wearing another tag.
  [(if highlit? :card :vbox) {:key (if highlit? :body-card :body-plain)
                              :spacing 2 :margin 0}
   ;; Who, when, and what can be done about it, on one line above the
   ;; words: the name and the time say where the message came from, and the
   ;; chips at the far end are the two answers to it.
   [:vbox {:key :who}
    ;; An event has no sender to head it, but it still happened at a time,
    ;; and a column of joins and quits with no clock on it says nothing
    ;; about how long the room was quiet. The time alone is that heading.
    (when (and (:system? m) (:at m))
      [:dim-label {:label (clock/clock-time (:at m))}])
    (when-not (:system? m)
      ;; Everything that is about the person rather than the line: their
      ;; picture, their name, and when they started saying this.
      [:hbox {:spacing 6}
       ;; Always an avatar, picture or not: the initial stands in until the
       ;; fetch lands, and for the guests who have no profile at all, which
       ;; is what keeps the column of faces straight down the left.
       ;; Reading the tick subscribes this row to a fetch finishing.
       ;; The face is also the way to the person behind it: Vidya's plain
       ;; label does not answer the pointer, so the tap sleek puts on the
       ;; nick lives here, on the one thing in the row that does.
       ;; And, where there is a pointer to ask with, resting on the face
       ;; answers before the click does: the card under it is the profile
       ;; screen's first few lines, painted beside the pointer.
       ;; And no face on this line in a terminal: the initial that stands in
       ;; for a portrait in a window is a letter printed twice in a cell grid,
       ;; which only pushed every nick in past the words it heads. Where the
       ;; terminal can draw a picture there is a face after all, hung beside
       ;; the whole message rather than off its heading — `message-row` has it.
       (when-not @terminal?
         (let [_ @s/media-tick]
           [:avatar (cond-> {:label (:from m)
                             :src (or (avatars/path-when-ready (:actor m)) "")
                             :size face-size
                             :on-click #(profile/open! (:from m) (:actor m))}
                      (platform/desktop?)
                      (assoc :on-hover #(profile/hover! (:from m) (:actor m))
                             :on-unhover #(profile/unhover! (:from m))))
            ;; Only the hovered face carries one: a card is painted when its
            ;; node has children, and the pointer is on one face at a time.
            (when (and (platform/desktop?)
                       (= (:from m) (:nick @profile/hovering)))
              [hover-card (:from m) (:actor m)])]))
       ;; The name carries the row, so it is set at body size in the plain
       ;; text colour: dimmed caption made the one thing you scan a column
       ;; for the faintest thing on it.
       [:label {:label (:from m)}]
       (when-let [at (:at m)]
         [:dim-label {:label (clock/clock-time at)}])
       ;; Beside the clock, because it is the same kind of fact about the
       ;; line: what is on screen is not what was first said.
       (when (:edited? m)
         [:dim-label {:label "(edited)"}])
       ;; And the two things you can do to the message, at the far end of
       ;; its heading: a nested row laid out from the right takes what is
       ;; left of the width and puts the chips against the edge of it, so
       ;; the words below keep the whole column.
       ;;
       ;; A key of its own for each branch, rather than one key whose node
       ;; changes tag under it: a line this client sent has no msgid until
       ;; the server echoes it back, and swapping a `:spacer` for a chip in
       ;; place is what left the row rebuilt in the wrong order.
       (if (:id m)
         [action-chips {:key :actions} @s/current m]
         [:spacer {:key :actions-gap :size 0}])])]
   ;; A little air under the sender's row: the name and face are a heading
   ;; for what follows, and a heading that touches its text is not one.
   ;; The text keeps a column of its own: a wrapping label directly in a
   ;; row wraps against the row.
   (indented
    :text
    [:vbox {:key :text :spacing 2 :margin-top 4}
     ;; What this answers, in the column the answer itself is in: the chip
     ;; is a quote of a line, so it wraps to the width a line has. Outside
     ;; this column it wrapped to the whole row instead — wider than any
     ;; message, and out to the window's edge on a narrow screen.
     [:vbox {:key :reply-chip}
      (when-let [reply-to (:reply-to m)]
        [reply-chip @s/current reply-to])]
     (map-indexed (fn [j run] (run-node j run (:system? m)))
                  (text-runs (:text m)))])
   ;; And the picker, when this is the message it was opened on: under the
   ;; line it is about, where the reader is already looking.
   ;;
   ;; The id has to exist, not merely match: a line this client sent itself
   ;; has no msgid, and neither does a closed picker — so `nil = nil` was
   ;; every one of those messages opening a picker of its own at startup.
   [:vbox {:key :picker :margin-bottom 4}
    (when (and (:id m) (= (:id m) (:id @s/reacting)))
      [emoji-picker])]
   ;; Pictures under the line that linked them. The link stays: it is what a
   ;; failed fetch, an unsupported format, or a phone with no TLS leaves you.
   (indented
    :images
    [:vbox {:key :images :spacing 4}
     (when (seq (:images m))
       ;; Reading the tick is what subscribes this row to a fetch finishing.
       (let [_ @s/media-tick]
         (for [url (:images m)]
           (when-let [path (media/path-when-ready url)]
             [:image {:key url
                      :src path
                      :max-height (preview-height)
                      :max-width (preview-width)
                      :on-click #(reset! s/lightbox {:path path :url url})}]))))])
   ;; Reactions go last, under whatever the message turned out to be: a
   ;; line with a picture on it is the picture, and pills between the words
   ;; and the image they introduce read as reactions to the words alone.
   ;; Nothing moves for a message with no picture — the box above it is
   ;; empty, and the pills still sit under the last line of text.
   (indented
    :reactions-row
    [:vbox {:key :reactions-row :margin-top 6}
     (when (and (:id m) (not (:system? m)) (seq (:reactions m)))
       [reaction-row @s/current m])])])

(defn message-row
  "One message: who said it, when, what you can do to it, and the words.

  Every line names its sender, rather than the first of a run only. A run
  collapsed to one heading reads well until you answer the fourth line of it,
  and then the line quoted back has no name on it; and the actions live on the
  sender's row, which a headerless line has nowhere to put.

  Sender above the text, not beside it: a wrapping label in a horizontal row
  lays out against the row's width rather than the column's, so one long URL
  drags every line that follows it off the left edge."
  [i m]
  (let [;; What a jump landed on wears a surface of its own for a moment, so
        ;; the answer to "which one was I sent to" is on the screen rather
        ;; than in the reader's count of rows.
        highlit? (boolean (and (:id m) (= (:id m) @s/highlight)))]
    [:vbox {:key i :spacing 2 :margin 0
            ;; Clear of the right edge: the actions ride that edge, and the
            ;; list's scrollbar rides it too — without this the ↩ is what the
            ;; scrollbar is drawn over.
            :margin-right 10
            ;; One gap between messages: every line carries its own heading
            ;; now, so there are no runs to hold together and nothing for a
            ;; closed-up line to belong to.
            :margin-top 10
            ;; The jump target is what a "go to message" click scrolls to.
            :scroll-here (boolean (and (:id m) (= (:id m) @s/jump-to)))}
     ;; The gap above, where the margin cannot be one. `:margin-top 10` is
     ;; most of a row in a window and nothing at all in a terminal — ten points
     ;; against a row of sixteen, rounded down, because a gap that thin is what
     ;; it looks like at this size. So the terminal buys the row outright:
     ;; without it every message in the backlog touches the one above it, and a
     ;; conversation reads as one paragraph with names scattered through it.
     (when @terminal? [:spacer {:key :gap :size 16}])
     ;; The face beside the message, where the terminal can draw one: a
     ;; portrait is two rows tall and a heading is one, so hanging it off the
     ;; sender's line would leave its lower half beside a blank row. Here the
     ;; words take that row, and the column the face makes is the indent every
     ;; other row of the message is held in by — `indented` steps aside for it.
     (if (terminal-face?)
       [:hbox {:key :faced :spacing 8}
        [:vbox {:key :face :width-request face-size}
         (let [_ @s/media-tick]
           (when-let [path (avatars/path-when-ready (:actor m))]
             [:image {:key :picture
                      :src path
                      :max-width face-size
                      :max-height face-size}]))]
        [message-body m highlit?]]
       [message-body m highlit?])]))

(defn- day-separator [day-key label]
  [:vbox {:key day-key :spacing 4 :margin 0}
   [:separator {}]
   [:dim-label {:label label}]])

(defn- message-rows
  "The messages, with a heading wherever the day changes.

  A backlog can reach back weeks, and `11:04 AM` says nothing about which day
  it was. The heading is what makes the time above it mean something."
  [messages]
  (mapcat (fn [i m]
            (let [prev (when (pos? i) (nth messages (dec i)))
                  day (some-> (:at m) clock/day)
                  new-day? (and day (not= day (some-> (:at prev) clock/day)))]
              (cond-> []
                new-day? (conj (day-separator (str "day-" i) (clock/day-label (:at m))))
                ;; A new day breaks the run: the first line under a heading
                ;; names its sender and its time, whoever spoke last night.
                ;; Keyed by the line itself, not by where it sits: the list is
                ;; reconciled by position when its children are not all keyed,
                ;; and a line that arrives anywhere but the end — a backlog
                ;; replay, an echo taking the place of what was sent — shifts
                ;; every row after it onto the widgets of its neighbour.
                true (conj ^{:key (or (:id m) (str "row-" i))}
                           [message-row i m]))))
          (range (count messages))
          messages))

(defn profile-screen
  "Who someone is: sleek's peer profile modal, as a screen.

  A screen rather than a layer for the same reason the lightbox is one — the
  tree backend paints in a single layer, with no z-order to hang a modal from.
  So the back row does what sleek's ✕ and backdrop did.

  The picture is the same cached file the chat column draws, at a size worth
  looking at; the bio is split into a label a line, so a bio that was written
  as several lines is still several lines here."
  []
  (let [{:keys [nick actor]} @profile/viewing
        ;; Reading both ticks subscribes this screen to the two fetches it is
        ;; waiting on: the profile itself, and the picture on it.
        _ @profile/tick
        _ @s/media-tick
        pr (profile/entry actor)
        ready? (= :ready (:status pr))
        display (or (:display-name pr) nick)
        url (when ready? (profile/web-url pr))]
    [:page {:max-width 520}
     [:hbox {:spacing 8}
      [:button {:label "← Back" :on-click profile/close!}]]
     [:card {}
      [:hbox {:spacing 12}
       [:avatar {:label nick
                 :src (or (avatars/path-when-ready actor) "")
                 :size 72}]
       [:vbox {:spacing 2}
        [:title-2 {:label display}]
        ;; The nick under the display name only when they differ — repeating
        ;; it is a line that says nothing.
        [:vbox {:key :nick}
         (when (not= display nick) [:dim-label {:label nick}])]
        [:vbox {:key :handle}
         (when-let [h (and ready? (not-empty (or (:handle pr) "")))]
           [:label {:label (str "@" h)}])]]]
      ;; The DID is the identity itself, and outlasts both the nick and the
      ;; handle — so it is on the screen, in full, rather than implied.
      [:vbox {:key :did :spacing 2}
       (when-let [did (:did pr)] [:dim-label {:label did}])]
      [:vbox {:key :bio :spacing 2}
       (when-let [bio (and ready? (:description pr))]
         (for [[i line] (map-indexed vector (str/split-lines (profile/truncate bio 600)))]
           [:label {:key i :label line}]))]
      [:vbox {:key :stats}
       (when-let [line (and ready? (profile/stats-line pr))]
         [:dim-label {:label line}])]
      ;; What is happening, or why nothing is: a guest has no identity to look
      ;; up, and saying so is a better answer than a spinner that never lands.
      [:vbox {:key :status :spacing 4}
       (cond
         (nil? actor)
         [:dim-label {:label "Guest — no Bluesky / AT Protocol identity"}]

         (= :loading (:status pr))
         [:hbox {:spacing 8}
          [:spinner {}]
          [:dim-label {:label "Loading Bluesky profile…"}]]

         (= :failed (:status pr))
         [:dim-label {:label "No Bluesky profile found"}])]
      [:vbox {:key :actions}
       (when url
         [:button {:label "Bluesky ↗"
                   :kind :primary
                   :on-click #(platform/open-url! url)}])]]]))

(defn lightbox-screen
  "One picture, as big as the window will paint it.

  A screen rather than an overlay: the tree backend paints in one layer and has
  no z-order to put something on top of everything else with. So the picture
  takes the window — `:fit` gives it every point below the one row that is not
  it, centred and in proportion, scaled up as readily as down.

  That row is the way back. Clicking the picture closes it too — the same
  gesture that opened it — but a way out you have to guess at is not one, and
  the row costs the picture a line."
  []
  (let [{:keys [path]} @s/lightbox]
    [:vbox {:spacing 4 :margin 4}
     [:hbox {:spacing 8}
      [:button {:label "← Back" :on-click #(reset! s/lightbox nil)}]]
     [:image {:src path :fit true :on-click #(reset! s/lightbox nil)}]]))

(defn- call-tile
  "One participant's picture, at the width the row worked out for it.

  `:feed` rather than `:src`: these pixels never touch the disk and never
  become a value here — the media plane hands the decoder's own buffer to
  Vidya as a pointer, and the tag paints whatever arrived last under that name.

  The height is three quarters of the width, which is the shape a camera hands
  over. Naming both keeps a portrait phone from making its tile tall enough to
  push the row off the screen — the picture is fitted inside, never stretched."
  [width key]
  (let [mine? (= av/local-feed key)]
    [:vbox {:key key :spacing 2}
     ;; `:upscale` because a tile is a slot the layout sized, not a picture
     ;; sitting at whatever the camera happened to send. Without it a 480-wide
     ;; stream draws 480 wide in a 900-point slot and the wall looks broken —
     ;; which is exactly what it did.
     [:image {:feed key
              :upscale true
              :max-width width
              :max-height (long (* width 0.75))}]
     [:dim-label {:label (if mine? "You" key)}]]))

(defn- call-wall
  "Everyone with a camera on, sized to the window they are being watched in.

  A call with no video is the normal case and should look like one — a row of
  empty frames would suggest something had failed to load.

  Both cells this reads are what subscribe it: `av/tiles` for who is on
  screen, and the window width so the tiles follow a window being dragged.
  Without either it would lay itself out once, on the first frame, and keep
  that shape for the rest of the call."
  []
  (let [[width rows] (av/tile-rows)]
    [:vbox {:key :call-wall :spacing 6}
     ;; A seq, not a vector: children splice, and a vector would be read as one
     ;; more hiccup element — which an empty one is not.
     (for [[i keys] (map-indexed vector rows)]
       [:hbox {:key i :spacing 8}
        (for [key keys]
          [call-tile width key])])]))

(defn- call-controls
  "What the person in a call can do about it.

  Mute and deafen are separate buttons because they are separate things: a
  deafened microphone still carries your voice, and one control for both would
  make the quieter of the two a surprise."
  []
  (let [{:keys [muted? speaker-muted? camera? has-camera? has-mic? media]} @av/local-call]
    [:vbox {:key :call-controls :spacing 6}
     [:hbox {:spacing 8}
      [:label {:label (case media
                        :waiting "Asking to join…"
                        :dialling "Connecting…"
                        :live "In call"
                        :failed "Call failed"
                        "In call")}]
      ;; A microphone that is not there is worth saying so: the call works,
      ;; and the person is listening rather than silent by choice.
      (when (and (= :live media) (not has-mic?))
        [:dim-label {:label "· listening only"}])]
     [:hbox {:spacing 8}
      [:button {:label (if muted? "Unmute" "Mute")
                :on-click #(av/set-muted! (not muted?))}]
      [:button {:label (if speaker-muted? "Undeafen" "Deafen")
                :on-click #(av/set-speaker-muted! (not speaker-muted?))}]
      ;; Only offered when there is a camera to turn on. Nothing is more
      ;; annoying than a control that does nothing and does not say why.
      (when has-camera?
        [:button {:label (if camera? "Stop video" "Start video")
                  :on-click #(av/set-camera! (not camera?))}])
      [:button {:label "Leave" :on-click #(s/leave-call!)}]]
     (when-let [e @av/media-error]
       [:dim-label {:label (str "⚠ " e)}])]))

(defn call-bar
  "The call in this channel, whatever state it is in. Always a node.

  Three cases, and the empty one matters as much as the others: a channel with
  no call must render *something* here, because the reconciler matches children
  by position and a banner that came and went would patch the message list into
  a button."
  [channel]
  [:vbox {:key :call-bar :spacing 6}
   (cond
     (av/in-call? channel)
     [:card {}
      [:vbox {:spacing 6}
       [call-controls]
       [call-wall]]]

     ;; A call is open in this room and we are not in it.
     (av/call-in channel)
     (let [{:keys [session-id participants title]} (av/call-in channel)]
       [:card {}
        [:hbox {:spacing 8}
         [:label {:label (str "📞 " (or title "Call in progress")
                              (if (and participants (pos? participants))
                                (str " · " participants)
                                ""))}]
         [:button {:label "Join"
                   :on-click #(s/join-call! channel session-id)}]]])

     ;; We are in a call, but in a different room. Say which, since the
     ;; controls are not on this screen to be found by looking.
     (av/in-call?)
     [:dim-label {:label (str "In a call in " (:channel @av/local-call))}]

     :else nil)])

(defn image-picker-screen
  "The pictures on this device, to send one of.

  A screen rather than a panel over the compose bar: choosing a file is
  browsing, and browsing wants the window — the backend paints in one layer
  anyway, so there is no overlay to put it in.

  A directory at a time, PNG only. Which directories there are to start from is
  the platform's answer, not this screen's: a desktop opens on ~/Pictures, and
  a phone on what the app can read without a permission it has no code to ask
  for, which may be very little. Either way the list says what it found."
  []
  (let [dir @s/image-picker
        {:keys [dirs files]} (s/picker-entries dir)
        up (s/parent-dir dir)]
    [:vbox {:spacing 8 :margin 12}
     [:hbox {:spacing 8}
      [:button {:label "← Back" :on-click s/close-image-picker!}]
      [:title {:label "Send a picture"}]]
     [:dim-label {:label (str dir)}]
     [error-note]
     ;; The places worth starting from, always in reach: browsing into a corner
     ;; of the filesystem should not cost the way back to the pictures folder.
     [:hbox {:key :roots :spacing 6}
      (for [root (s/picker-roots)]
        [:button {:key root
                  :label (or (last (str/split root #"/")) root)
                  :kind (if (= root dir) :primary :default)
                  :on-click #(s/browse! root)}])]
     [:separator {}]
     [:scroll {:scroll-key "image-picker"
               :orientation :vertical
               :reserve 40}
      [:vbox {:spacing 6}
       [:vbox {:key :up}
        (when up
          [:button {:label "⬆ Up" :on-click #(s/browse! up)}])]
       [:vbox {:key :dirs :spacing 4}
        (for [d dirs]
          [:button {:key d
                    :label (str "📁 " (last (str/split d #"/")))
                    :on-click #(s/browse! d)}])]
       ;; The picture itself is the button: a filename is not what anyone is
       ;; choosing between, and a thumbnail answers "is this the one" in a way
       ;; no name does.
       [:vbox {:key :files :spacing 6}
        (for [f files]
          [:hbox {:key f :spacing 8}
           [:image {:src f :max-height 72 :on-click #(s/pick-image! f)}]
           [:button {:label (last (str/split f #"/"))
                     :on-click #(s/pick-image! f)}]])]
       [:vbox {:key :empty}
        (when (and (empty? dirs) (empty? files))
          [:dim-label {:label "No pictures here that this app can read."}])]]]]))

;; What the people panel asks for, and what the conversation beside it has to
;; be told to leave. A column with `:fill-height` and no width takes the whole
;; row — so the panel is only ever on screen if the message list is given a
;; width that stops short of it.
(def ^:private users-width 180)

;; What the rows under the conversation need left to them: the jump button's
;; row, the separator, the compose bar and the air around it. The columns of
;; the row reserve it, and so nothing inside them has to — a `:scroll` that
;; subtracted it again inside a column already stopped short would take the
;; same points off the list twice.
;;
;; Plus the reply banner's row when there is one, and the pasted picture when
;; there is one. Those rows do move the compose bar, and should: each appears
;; because the reader just asked for something — unlike the jump button, which
;; appears on its own and must not shift what is under it.
(defn- below-messages []
  ;; 140 is that, counted: the gap under the row of columns, the jump button's
  ;; 34pt row, the separator and the two empty wrappers with a gap apiece, then
  ;; the compose row and the air under it — its own and the window's. Short by
  ;; any of it and the column runs past the bottom edge, which does not show as
  ;; a list that is too long: it shows as a compose bar sitting flat on the
  ;; bottom of the window with its margin cut off.
  (+ (* (chrome-scale)
        (+ 140
           (if @s/replying-to 34 0)
           (if @s/attachment 76 0)))
     ;; The two extra rows the terminal's compose field wraps into, in points:
     ;; a row down the page is two cells' worth of the scale.
     (if @terminal? (* 4 (chrome-scale)) 0)))

(defn- messages-width
  "How wide the message list may be with the people panel beside it.

  Measured from the window rather than from what egui has left: the row is
  painted left to right, and by the time the panel is placed the list has
  already taken everything. On a wide window the chats list is holding the
  first `sidebar-width` of the window; the rest is the margins and the gap
  between the two columns."
  []
  (let [pane (- @s/window-width (if (s/wide?) sidebar-width 0))]
    (max 240 (- pane users-width 8 28))))

(defn- member-row [{:keys [nick prefix]}]
  ;; The mode where there is one, dim: it says how someone is listed, not who
  ;; they are, and the name is what the eye is scanning for. A space where
  ;; there is none, rather than nothing at all: the label is always in the row,
  ;; so every name starts at the same place — and a column wrapped around a
  ;; label that comes and goes is a column, which sits its text against the top
  ;; of the row rather than on the line the name is on.
  ;;
  ;; The name is a button because a person is somewhere to go: pressing one
  ;; opens a conversation with them.
  [:hbox {:key nick :spacing 6 :wrap false}
   [:dim-label {:label (if (seq prefix) prefix " ")}]
   [:button {:label nick :on-click #(s/open-dm! nick)}]])

(defn users-panel
  "Who is in the channel, beside the conversation.

  The list is the server's — NAMES on the way in, kept up by the joins and
  parts after it — so a channel this client has never been in has nothing to
  show, and says so rather than showing an empty column."
  [name]
  (let [people (s/member-list name)]
    [:vbox {:key :users :width-request users-width :fill-height true
            :reserve (below-messages) :spacing 8}
     [:title-2 {:label (str "People " (count people))}]
     [:scroll {:scroll-key (str "users-" name)
               :orientation :vertical}
      (if (seq people)
        ;; Keyed, for the reason the conversation list is: this list reorders
        ;; as people come and go, and a name is a button someone can be
        ;; standing on.
        (for [p people] ^{:key (:nick p)} [member-row p])
        [:dim-label {:label "Nobody listed yet."}])]]))

(defn- messages-scroll-key
  "What the backlog's scroll position is remembered under.

  One name in a window: `:scroll-to-bottom` is how the jump button is answered
  there, and the position under that name is the one the reader left behind.

  The terminal backend has no `:scroll-to-bottom` — a viewport there is moved
  by the wheel and the page keys and by nothing else — but it does open a
  sticky viewport it has never seen at the bottom, which is the same thing
  said differently. So a jump renames the viewport: the tick that asks the
  window to scroll gives the terminal a name with no position saved under it,
  and the newest line is what it opens on.

  Only on a jump, so scrolling and every message that arrives between two
  jumps still find the position where they left it."
  []
  (if @terminal?
    (str "chat-messages-" @s/jump-tick)
    "chat-messages"))

(defn- policy-note
  "What this channel wants agreed to, and the one button that agrees to it.

  Above the backlog rather than in it: the refusal is already a line in the
  buffer, and a button scrolled away with last week's messages is a button
  nobody finds. The rules come from the server; when it has none to give, its
  own words about that are what shows."
  [name buffer]
  (when (:policy-required? buffer)
    [:vbox {:spacing 4}
     [:dim-label {:label (str name " asks you to accept its policy before joining.")}]
     (for [[i line] (map-indexed vector (:policy-text buffer))]
       ^{:key (str "policy-" i)} [:dim-label {:label line}])
     [:button {:label "Accept policy" :kind :primary
               :on-click #(s/accept-policy! name)}]]))

(defn chat-screen []
  (let [name @s/current
        buffer (get @s/channels name)
        show-users? (and @s/show-users? name (str/starts-with? name "#"))]
    ;; Not a :page — a page scrolls everything, which would carry the compose
    ;; bar off the bottom with the backlog. The message list is the only thing
    ;; that scrolls, bounded so what follows it keeps its room.
    ;; Same margin all round: the compose row's own air is what centres it in
    ;; the strip below the separator, and it is measured from this edge.
    ;; Ctrl-End is the jump without the button, for a reader whose hands are
    ;; on the compose bar. It is unhandled everywhere below — the entry takes
    ;; plain End for its own caret and leaves this one alone — so it arrives
    ;; here by bubbling up from whatever had the focus. The window backend
    ;; registers the handler and never calls it: keys there belong to egui.
    ;; `:fill-height` for the reason the chats screen gives on its own root:
    ;; without it this column is as tall as what is in it, and the compose bar
    ;; sits wherever the backlog happens to end rather than at the bottom.
    [:vbox {:spacing 8 :margin 12 :fill-height true
            :on-key (fn [k]
                      (when (= k "ctrl+end") (s/jump-to-present!)))}
     [:hbox {:spacing 8}
      ;; The way back to the list, on a window with room for one thing at a
      ;; time. Beside the list there is nothing to go back to, so the button
      ;; goes — in a wrapper of its own, since a child that comes and goes
      ;; would otherwise renumber the row for the reconciler.
      [:vbox {:key :back}
       (when-not (s/wide?)
         [:button {:label "← Chats" :on-click #(reset! s/screen :chats)}])]
      [:title {:label (or name "Chat")}]
      ;; Same wrapper trick: only in a channel, and only when there is no call
      ;; to join already — the bar below offers Join in that case, and two ways
      ;; into the same call is one more than anybody needs.
      [:vbox {:key :call}
       (when (and name
                  (str/starts-with? name "#")
                  (av/available?)
                  (not (av/call-in name))
                  (not (av/in-call?)))
         [:button {:label "Call" :on-click #(s/start-call! name)}])]
      ;; The people panel's switch, in a wrapper of its own for the same
      ;; reason: it is only offered in a channel, where there is a membership
      ;; to show.
      [:vbox {:key :people}
       (when (and name (str/starts-with? name "#"))
         [:button {:label (str "People " (s/member-count name))
                   :kind (when @s/show-users? :primary)
                   :on-click s/toggle-users!}])]]
     [error-note]
     ;; In a wrapper of its own, for the reconciler's sake: it comes and goes.
     [:vbox {:key :policy}
      (policy-note name buffer)]
     [call-bar name]
     ;; :reserve leaves room for everything below: the jump button's row, the
     ;; separator and the compose bar. It does not vary with whether the button
     ;; is showing, and neither does that row — a reserve that changed would
     ;; move the compose bar under the reader every time the button came and
     ;; went.
     ;; Named, so the list is the same list when the reader comes back to it.
     ;; The lightbox is a screen rather than a layer, so looking at a picture
     ;; unmounts the backlog behind it; without a name of its own the position
     ;; would come back as a fresh one, and ← Back would answer a click on a
     ;; message halfway up a week of history with the top of the buffer.
     ;; The backlog and, when it is asked for, who is in the room beside it.
     ;; The row is always there and the panel comes and goes inside a wrapper
     ;; of its own: a child that appeared and vanished would renumber the row
     ;; for the reconciler, and take the message list's scroll position with
     ;; it every time the panel was toggled.
     [:hbox {:spacing 8 :wrap false}
      [:vbox {:key :messages :fill-height true
              :width-request (if show-users? (messages-width) 0)}
       [:scroll {:scroll-key (messages-scroll-key)
                 :orientation :vertical
                 :reserve (below-messages)
                 :stick-to-bottom true
                 :scroll-to-bottom @s/jump-tick
                 :on-change #(reset! s/at-present? (= "end" %))
                 ;; The terminal's half of the same question, which arrives
                 ;; as the offset the list moved to rather than as a place.
                 ;; `scrolled!` is what turns one into the other.
                 :on-scroll s/scrolled!}
        (if (seq (:messages buffer))
          (message-rows (:messages buffer))
          [:dim-label {:label "Nothing here yet."}])]]
      ;; The wrapper takes no height of its own: the panel inside it is the
      ;; column, and a fill-height wrapper around it would claim the strip the
      ;; compose bar sits in whether or not the panel was showing.
      [:vbox {:key :people-pane}
       (when show-users? [users-panel name])]]
     ;; Only while it is needed, and directly above the compose bar: the way
     ;; back to the present belongs next to the thing that puts you there.
     ;; The row keeps its height whether or not the button is in it, so the
     ;; compose bar below stays where the reader last saw it.
     [:vbox {:key :jump}
      (if @s/at-present?
        [:spacer {:size 34}]
        ;; With the key beside it where there is a key: a terminal is where a
        ;; reader is least likely to reach for the mouse, and most likely to
        ;; have paged up here with the keyboard in the first place.
        [:button {:label (if @terminal?
                           "↓ Jump to present (Ctrl-End)"
                           "↓ Jump to present")
                  :on-click s/jump-to-present!}])]
     [:separator {}]
     ;; What the draft is answering, directly above where it is being typed.
     [:vbox {:key :replying}
      (when-let [target @s/replying-to]
        [:hbox {:spacing 8}
         [:dim-label {:label (str "↩ " (:from target) ": " (summarise target 36))}]
         [:button {:label "✕" :on-click s/cancel-reply!}]])]
     ;; And, in the same place, that the box holds a rewrite rather than
     ;; something new: the text in it is a copy of a line already on screen,
     ;; and without this Send would look like it was about to say it twice.
     [:vbox {:key :editing}
      (when @s/editing
        [:hbox {:spacing 8}
         [:dim-label {:label "✏️ Editing your message"}]
         [:button {:label "✕" :on-click s/cancel-edit!}]])]
     ;; The pasted picture, above the line it will go out with. Shown rather
     ;; than written into the draft: what is being sent is a picture, and a URL
     ;; dropped into the entry would be an unreadable line of text sitting in
     ;; the middle of whatever the reader was in the middle of typing.
     [:vbox {:key :attachment}
      (when-let [att @s/attachment]
        [:hbox {:spacing 8}
         ;; Small: it is a reminder of what is attached, not the picture
         ;; itself, and the backlog above it is what the reader is here for.
         [:image {:src (:path att) :max-height 64}]
         [:dim-label {:label (if (= :uploading (:status att))
                               "Uploading…"
                               "Picture attached")}]
         [:button {:label "✕" :on-click s/clear-attachment!}]])]
     ;; The line and its buttons on the middle of the width rather than
     ;; against its left edge: the entry asks for a fixed width, and on a
     ;; window wider than that a left-aligned row leaves it stranded in the
     ;; corner of an otherwise empty bar. On a phone the row is as wide as the
     ;; window and centring costs nothing.
     ;; Equal air above and below, so the row sits on the middle of the strip
     ;; between the separator and the bottom edge rather than flat against it.
     ;; Above it is four of the column's gaps: one after the separator and one
     ;; for each of the empty wrappers — the reply banner, the edit banner and
     ;; the attachment, which cost a gap apiece whether or not they have
     ;; anything in them. This margin plus the window's own is what answers
     ;; them underneath.
     [:hbox {:spacing 8 :align :center :margin-bottom 12}
      ;; narrow enough that Send keeps its place on a phone-width row
      ;; A picture is pasted where everything else is typed: Ctrl+V. The field
      ;; answers a paste of text with the text, and one of a picture reaches
      ;; `:on-paste-empty` — a keystroke the field had nothing to put in
      ;; itself, which is exactly the one that means "the clipboard has
      ;; something else on it".
      ;; And the same picture chosen rather than pasted, for a phone — which has
      ;; no Ctrl+V, and no clipboard of pictures to read if it had.
      [:button {:label "🖼" :on-click s/open-image-picker!}]
      ;; In a terminal the row is the width of the screen and a message is
      ;; longer than 260 points of it: the field takes the surplus and wraps
      ;; into three rows rather than scrolling one line sideways.
      [:entry {:text @s/draft
               :width-request 260
               :hexpand @terminal?
               :rows (if @terminal? 3 1)
               :placeholder "Message"
               :on-change #(reset! s/draft %)
               :on-paste-empty s/paste-image!
               :on-activate s/send-draft!}]
      [:button {:label "Send" :kind :primary :on-click s/send-draft!}]]]))

;; ---------------------------------------------------------------- split

(defn- no-chat-pane
  "What fills the second pane before a conversation has been picked. The pane
  is there either way — a list that widened into two columns and back again as
  channels were opened would be a worse answer than an empty half."
  []
  [:vbox {:spacing 8 :margin 12}
   [:title {:label "frq"}]
   [:card {} [:dim-label {:label "Pick a conversation on the left."}]]])

(defn split-screen
  "The chats list and the conversation side by side, for a window wide enough
  to hold both.

  Same components as the narrow layout, in a row instead of one at a time: the
  list keeps its own scroll and its own tab bar, and the conversation keeps the
  compose bar pinned under a backlog that scrolls on its own.

  Both panes take `:fill-height`: a column in a row is otherwise as tall as the
  row, which at the moment it is placed is one button — and the list and the
  message backlog both size themselves against the height they are handed.

  Only the list is given a width. The conversation takes what is left, rather
  than the window's width minus the list's: the list costs a little more than
  its 320 (its page has padding of its own), and a second column asking for
  more than remains is wrapped onto a row below — painting the whole
  conversation off the bottom of the window, which reads exactly like a
  conversation that has gone missing."
  []
  [:hbox {:spacing 0 :wrap false}
   [:vbox {:key :list :width-request sidebar-width :fill-height true}
    [chats-screen]]
   [:vbox {:key :chat :fill-height true}
    (if @s/current
      [chat-screen]
      [no-chat-pane])]])

;; ---------------------------------------------------------------- discover

(defn discover-screen []
  [:page {:max-width 620}
   [:title {:label "Discover"}]
   [:dim-label {:label "Popular channels on freeq."}]
   [error-note]
   (for [[name blurb] s/popular-channels]
     (let [joined? (get-in @s/channels [name :joined?])]
       [:card {:key name}
        [:title-2 {:label name}]
        [:dim-label {:label blurb}]
        [:button {:label (if joined? "Open" "Join")
                  :kind :primary
                  :on-click #(if joined? (s/open-channel! name) (s/join! name))}]]))
   [:separator {}]
   [tab-bar]])

;; ---------------------------------------------------------------- settings

(defn settings-screen []
  [:page {:max-width 520}
   [:title {:label "Settings"}]
   [:card {}
    [:title-2 {:label "Connection"}]
    [:status {:label @s/status :live (s/connected?)}]
    [:label {:label (str "Server: " @s/form-host ":" @s/form-port)}]
    [:label {:label (str "Nick: " @s/form-nick)}]
    (if-let [sess @s/session]
      [:vbox {:spacing 2}
       [:label {:label (str "Signed in as " (:handle sess))}]
       [:dim-label {:label (or (:did sess) "")}]
       [:vbox {:key :forget}
        (when @s/broker-token
          [:button {:label "Forget Bluesky session"
                    :kind :destructive
                    :on-click s/forget-session!}])]]
      [:dim-label {:label "Guest — not signed in."}])
    [:separator {}]
    ;; Nothing to disconnect from when there is no connection — the way back to
    ;; the connect screen is what is wanted then.
    [:vbox {:key :connection-action}
     (if (s/connected?)
       [:button {:label "Disconnect" :kind :destructive :on-click s/disconnect!}]
       [:button {:label "Back to connect"
                 :on-click #(reset! s/screen :connect)}])]]
   [:card {}
    [:title-2 {:label "Messages"}]
    [:checkbutton {:label "Hide join/part messages"
                   :active @s/hide-join-part?
                   :on-toggled s/toggle-hide-join-part!}]
    [:dim-label {:label "Hides other people arriving, leaving and quitting. The people panel still follows who is here."}]]
   [:card {}
    [:title-2 {:label "frq"}]
    [:dim-label {:label "freeq client in jolt — glimmer components on the Vidya/egui backend."}]
    [:button {:label "Quit" :on-click gui/quit!}]]
   [:separator {}]
   [tab-bar]])

;; ---------------------------------------------------------------- shell

(defn app []
  ;; Every branch in its own keyed wrapper, and every key different.
  ;;
  ;; Without them the screens are all one position in the tree, and moving
  ;; between two of them is a diff of one screen's children against another's:
  ;; the reconciler matches what it can by position and patches the rest, which
  ;; leaves nodes from the screen you left standing in the one you arrived at —
  ;; the chats screen's join box turning up under its tab bar, an error box
  ;; from the conversation you were in a moment ago. A key that changes with
  ;; the screen makes the swap a swap: the old tree comes out whole and the new
  ;; one goes in whole.
  (cond
    @s/lightbox [:vbox {:key :screen-lightbox} [lightbox-screen]]
    @profile/viewing [:vbox {:key :screen-profile} [profile-screen]]
    @s/image-picker [:vbox {:key :screen-picker} [image-picker-screen]]
    ;; Wide enough for both, and on one of the two screens that are halves of
    ;; the same thing: the list and the conversation it opens. Discover and
    ;; settings stay whole screens — they are somewhere else, not the other
    ;; half of here.
    (and (s/wide?) (contains? #{:chats :chat} @s/screen))
    [:vbox {:key :screen-split} [split-screen]]
    :else (case @s/screen
            :connect [:vbox {:key :screen-connect} [connect-screen]]
            :chat [:vbox {:key :screen-chat} [chat-screen]]
            :discover [:vbox {:key :screen-discover} [discover-screen]]
            :settings [:vbox {:key :screen-settings} [settings-screen]]
            [:vbox {:key :screen-chats} [chats-screen]])))

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

(defn -main [& _]
  (start! {:after! gui/after!
           :every! gui/every!
           :title! gui/set-title!
           ;; The height comes off the same tick, from `screen-size` rather
           ;; than a second call: it is the window's content size, and the
           ;; pictures in the conversation are sized against it.
           :measure! (fn []
                       (let [w (gui/window-width)
                             h (long (second (gui/screen-size)))]
                         (when (not= w @s/window-width)
                           (reset! s/window-width w))
                         (when (not= h @s/window-height)
                           (reset! s/window-height h))))})
  (ui/run app :title "frq" :width 520 :height 860))
