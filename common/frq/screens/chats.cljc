(ns frq.screens.chats
  "The conversation list, shared.

  The second screen out of `frq.app`, and like the first it moved rather than
  changed: the same hiccup, reading `frq.cells` and `frq.rooms` instead of
  `frq.state`, and calling `frq.actions` instead of the reducers.

  `error-note` and `tab-bar` come with it because the list is not the only
  screen that shows them — the chat screen and settings do too, and they will
  want this namespace rather than a second copy when their turn comes."
  (:require [clojure.string :as str]
            [frq.actions :as actions]
            [frq.cells :as cells]
            [frq.metrics :refer [chrome-scale terminal?]]
            [frq.rooms :as rooms]
            [frq.screens.connect :refer [error-note]]))

(defn tab-bar []
  [:hbox {:spacing 8}
   (for [[k label] [[:chats "Chats"] [:discover "Discover"] [:settings "Settings"]]]
     [:button {:key k
               :label label
               :kind (if (= k @cells/screen) :primary :default)
               :on-click #(reset! cells/screen k)}])])


;; Whether the backend under this tree is a terminal, set by `frq.tui` before
;; the first paint and never again. Two things in a message hang on it, and
;; both are about a cell grid rather than a canvas: there is no picture to
;; draw a face with, and a name with nothing to its left is the heading the
;; text hangs off — the shape a terminal has read messages in for forty years.

(def ^:private list-gutter 16)

(defn- below-list []
  ;; What the strip under the list needs, counted: the gap after the list, the
  ;; separator, the gap under it, the tab bar's row of buttons and the margin
  ;; below them. Short by any of it and the tabs go off the bottom edge — which
  ;; is the thing this layout exists to stop.
  (* (chrome-scale) (+ 8 8 8 34 12)))

(defn- preview-line
  "The last line of a conversation, as one line: a pasted shell script or a
  long link is a card's worth of text otherwise, and the cards stop reading as
  a list of rooms."
  [text]
  (let [line (str/replace (str text) #"\s+" " ")]
    ;; 60 rather than a card's worth: at `sidebar-width` a 90-character line is
    ;; three wrapped rows, and three rows of somebody else's last sentence is
    ;; the row shouting over the name above it. One row of it says which
    ;; conversation this is, which is all the list is for.
    (if (> (count line) 60)
      (str (subs line 0 59) "…")
      line)))

;; What everything in the chats pane keeps clear of its right edge.
;;
;; It is one number because it is one edge: the scrollbar rides it, and the
;; cards in the list have to stop short of the bar rather than be drawn under
;; it — but the Join box above the list is outside the scroll and has no bar
;; beside it, so left to itself it ran on past the cards and the pane had two
;; right edges half a finger apart. Whatever the gap is, both of them take it.

(defn- close-button [name]
  [:button {:label "Close"
            :on-click #(actions/leave-channel! name)}])

(defn- open-button [name]
  [:button {:label "Open"
            :on-click #(actions/open-channel! name)}])

;; The only way out of a room. Everything else adds one — the server saying we
;; are in it, a message arriving in it — so without this the list only grows,
;; and what rooms.edn claims we are in could never shrink.

(defn conversation-row [buffer]
  (let [name (:name buffer)
        ;; Defaulted rather than assumed. Everything that builds a buffer
        ;; goes through `ensure-channel`, but the list draws whatever is in
        ;; the atom, and a half-made room reaching here should be a row that
        ;; reads as quiet rather than the frame that killed the client.
        unread (:unread buffer 0)]
    ;; The card in a wrapper that holds it off the right edge, where the
    ;; list's scrollbar rides — `message-row` keeps its actions clear of the
    ;; same edge for the same reason, and without it the cards are drawn
    ;; under the bar rather than beside it. The wrapper and not the card
    ;; itself: the window backend pads a card by a fixed 12 and never reads a
    ;; margin off one, so the room has to be taken outside it.
    [:vbox {:key name :margin-right list-gutter}
     [:card {}
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
      ;; The badge line, and only when there is a badge: every row carrying a
      ;; green "joined" was a row spending a third of its height saying the
      ;; ordinary thing, and a list where every card says the same word is a
      ;; list you read by skipping. So membership is reported when it is news —
      ;; a room in the list we are not in — and a DM says nothing at all, since
      ;; there is no membership to have and the name already says what it is.
      ;;
      ;; In a wrapper of its own, because the line comes and goes with the
      ;; unread count and the reconciler numbers a card's children by position.
      ;; `:wrap false` on the badges: they sit beside each other or not at all.
      [:vbox {:key :badges}
      (let [away? (and (not (rooms/dm? name)) (not (:joined? buffer)))]
        (when (or away? (pos? unread))
          [:hbox {:spacing 12 :wrap false}
           (when away?
             [:status {:label "not joined" :live false}])
           ;; A mention is not more unread, it is different unread: the dot
           ;; says how much there is and the name says it was aimed at you.
           ;; Both or neither — a room with your name in it always has a line
           ;; to count.
           (when (pos? unread)
             [:label {:label (str (if (:mention? buffer) "◆ @ " "● ") unread)}])]))]
      [:dim-label {:label (preview-line (rooms/last-preview buffer))}]
      (when-not @terminal?
        [:hbox {:spacing 8 :wrap false}
         [open-button name]
         [close-button name]])]]))

(defn chats-screen []
  (let [buffers (rooms/channel-list)]
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
     [:vbox {:key :head :spacing 8 :margin-right list-gutter}
       ;; Your nick in the title, where "Chats" alone said nothing you did not
      ;; already know — and said plainly, as a sign-in rather than as a name
      ;; the list is somehow held in. It is what every channel calls you and
      ;; what your own lines are signed with, and the only other place it
      ;; showed was Settings.
      [:title {:label (if (actions/connected?)
                        (str "Logged in as " @cells/form-nick)
                        "Chats")}]
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
         [:button {:label (if (str/starts-with? @cells/join-input "@") "Message" "Join")
                   :kind :primary
                   :on-click #(do (actions/join! @cells/join-input) (reset! cells/join-input ""))}]
         ;; Both kinds of conversation through one box: `#room` joins a
         ;; channel, `@nick` opens a message to a person.
         [:entry {:key :join-input
                  :text @cells/join-input
                  :placeholder "#channel or @nick"
                  :on-change #(reset! cells/join-input %)
                  :on-activate #(do (actions/join! @cells/join-input) (reset! cells/join-input ""))}]]
        ;; The clear button only shows while there is something to clear: an
        ;; empty box has nothing to undo, and a dead button beside it reads as
        ;; one that stopped working. It leads the row for the same reason the
        ;; Join button does, and the box gives up the width it takes.
        [:hbox {:spacing 8 :align :end}
         (when (seq @cells/search)
           [:button {:label "✕" :on-click #(reset! cells/search "")}])
         [:entry {:key :search
                  :text @cells/search
                  :placeholder "Search channels"
                  :on-change #(reset! cells/search %)}]]]]]
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
         ;; The gap between cards, and it has to be here rather than on the
         ;; card: a card is padded inside by the backend and takes no margin of
         ;; its own, so cards handed straight to the scroll sit edge to edge and
         ;; the list reads as one ruled block instead of a row per conversation.
         ;; 8, the same step the bands above use.
         [:vbox {:spacing 8}
          (for [b buffers] ^{:key (:name b)} [conversation-row b])]
         [:vbox {:margin-right list-gutter}
          [:card {} [:dim-label {:label "No conversations yet — join a channel."}]]])]]
     [:vbox {:key :foot :spacing 8}
      [:separator {}]
      [tab-bar]]]))\n