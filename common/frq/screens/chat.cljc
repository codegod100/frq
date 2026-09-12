(ns frq.screens.chat
  "The conversation, shared.

  The largest of frq.app's screens and the last of its three big ones: the
  message list with its replies, edits and reactions, the emoji picker, the
  people panel, the overview, the call wall and the compose bar.

  It moved the way the other two did — the same hiccup, reading `frq.cells`
  and `frq.rooms`, calling `frq.actions`. What is different here is how much
  of it is not state at all: where a face or a picture is on disk is a fetch
  and a cache, and a call is a media plane, so those are actions rather than
  cells and a platform that has neither simply does not install them. The
  screen then draws what it already draws when a face has not arrived yet."
  (:require [clojure.string :as str]
            [frq.actions :as actions]
            [frq.cells :as cells]
            [frq.clock :as clock]
            [frq.emoji :as emoji]
            [frq.glyphs :as glyphs]
            [frq.metrics :refer [chrome-row chrome-scale terminal? terminal-face?]]
            [frq.rooms :as rooms]
            [frq.screens.chats :refer [preview-line tab-bar]]
            [frq.screens.connect :refer [error-note]]))

(def ^:private text-emoji-size
  "An emoji in a message, at the size of the words around it. Bigger and the
  line it sits in grows to make room for it; smaller and it reads as a
  footnote on the sentence rather than a word of it."
  14)

(def ^:private pill-size
  "How big a reaction is under a message. Small: it is a footnote on what was
  said, not a second thing said."
  14)

(def ^:private picker-columns
  "Emoji to a row, at the picker's own size. Narrow enough that the grid fits a
  phone-width window, which is the width this app is laid out for."
  9)

(defonce ^:private draft-rows (atom 1))

;; How tall the compose field is allowed to grow. The same ceiling in both
;; backends, for different reasons: a window past it scrolls with the caret in
;; view, and a terminal past it would be spending a quarter of the screen on
;; a message that has not been sent yet.
(def ^:private draft-max-rows 5)

(defn- terminal-draft-rows
  "How many rows the terminal's compose field wants for what is in it.

  The library sizes an entry by the `:rows` it was given and reports nothing
  back — there is no `:on-rows` to grow on, the way a window grows — so the
  wrapping is counted here instead, and the answer is both what the field is
  given and what `below-messages` keeps for it.

  An empty field is one row, so the bar starts as a line rather than as a
  block of ruled nothing, and the text begins at the top of the rect and grows
  downwards from there.

  The width is the row less what is beside the field — the picture button, the
  Send button, and the gaps around them, about twenty-two cells of eight points
  each. An estimate, and the cheap way to be wrong: a row over-counted is a row
  of conversation, where a row under-counted is a line of the draft with
  nowhere to go."
  []
  (let [cols (max 20 (quot (- @cells/window-width (* 22 8)) 8))
        ;; Ceiling division, written out: `Math/ceil` is Java and there is no
        ;; Math under ClojureDart — the same reason `frq.clock` spells out
        ;; floor-div. Integers throughout, so no float rounds a line the wrong
        ;; way at the boundary either.
        wrapped (fn [line] (max 1 (quot (+ (count line) cols -1) cols)))]
    (min draft-max-rows
         (max 1 (reduce + (map wrapped (str/split-lines (or @cells/draft ""))))))))

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
;; What the overview strip costs the conversation above it, in points: a row
;; for its heading, a row a line, and the separator and gaps around them. The
;; backlog's `:reserve` takes this too, so the strip is paid for out of the
;; conversation rather than pushing the compose bar off the bottom — which is
;; what every other row under the message list has had to say for itself.
;;
;; Counted from the lines there actually are, not from the ceiling: the strip
;; holds at most `overview-lines` of them there, and a room with two lines in
;; it should not have a screenful reserved against it.
;;
;; The window reserves nothing for the overview. Its pane scrolls and fills,
;; so it takes its half of the column by being in it — there is no number to
;; subtract, and subtracting one would take the room twice.

(def emoji-groups
  "Unicode's own grouping, which is what the picker's tabs are."
  emoji/groups)
(def picker-limit
  "How many glyphs the picker will lay out at once — twelve rows of the nine it
  fits across. It stands inside the message list, so what it shows pushes the
  conversation down; a group that has more says so, and the search box is how
  you reach the rest."
  108)
(def overview-lines 8)

(defn- overview-list-height
  "How tall the strip's list of lines is, in points.

  The number is both the reserve the backlog is laid out against and the
  height the terminal's scroll is given, and it has to be one number: a pane
  an inch taller than what was kept for it is a compose bar an inch off the
  bottom of the screen.

  Counted from the lines there are, up to the ceiling — a room with two lines
  in it should not have a screenful reserved against it — and from the ceiling
  once there are more, which is the point at which the pane starts scrolling
  instead of growing.

  A row of chrome a line, not the twenty points a window's line box is: a line
  here is one row of the terminal, and twenty points of a window's scale comes
  out as a little over half of one. Eight lines then asked for five rows, got
  five, and cut three lines off a strip that had just been given a scroll to
  show them in."
  []
  (* @chrome-row (min overview-lines (count (actions/recent-everywhere)))))

(defn- overview-height []
  (+ (overview-list-height) (* (chrome-scale) (+ 24 16))))

(defn- below-messages []
  ;; 115 is that, counted: the gap under the row of columns, the jump button's
  ;; 34pt row, the banners in their one wrapper with one gap, then the compose
  ;; row and the air under it — its own and the window's. Short by any of it
  ;; and the column runs past the bottom edge, which does not show as a list
  ;; that is too long: it shows as a compose bar sitting flat on the bottom of
  ;; the window with its margin cut off.
  ;;
  ;; It was 140 when a rule was drawn above the compose bar and the three
  ;; banners each cost the column a gap of their own. The rule went, and they
  ;; went into one wrapper: twenty-five points of nothing, given back.
  (+ (* (chrome-scale)
        (+ 115
           (if @cells/replying-to 34 0)
           (if @cells/attachment 76 0)))
     ;; The rows the compose field has GROWN by, and the row of air above it.
     ;;
     ;; Twenty points a line in a window: a 16-point face's line box rounded
     ;; up, and the reserve has to be at least what the field took, because a
     ;; point too few does not crop the list — it slides the compose bar off
     ;; the bottom of the window. `draft-rows` is what the field reported.
     ;;
     ;; A row of chrome a line in a terminal, counted here rather than
     ;; reported: nothing there fires `:on-rows`, so `terminal-draft-rows` is
     ;; asked the same question the field was given its height by. It used to
     ;; be a fixed three rows whatever was in it, two of them blank.
     (if @terminal?
       (* @chrome-row (terminal-draft-rows))
       (* 20 (dec @draft-rows)))
     ;; And the overview strip, when it is up. Reserved here rather than
     ;; anywhere else because this is the number the backlog is laid out
     ;; against: without it the strip is drawn past the bottom of the window
     ;; and takes the compose bar with it.
     (if (and @terminal? @cells/overview?) (overview-height) 0)))

(defn- call-controls
  "What the person in a call can do about it.

  Mute and deafen are separate buttons because they are separate things: a
  deafened microphone still carries your voice, and one control for both would
  make the quieter of the two a surprise."
  []
  (let [{:keys [muted? speaker-muted? camera? has-camera? has-mic? media]} (actions/local-call)]
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
                :on-click #(actions/set-muted! (not muted?))}]
      [:button {:label (if speaker-muted? "Undeafen" "Deafen")
                :on-click #(actions/set-speaker-muted! (not speaker-muted?))}]
      ;; Only offered when there is a camera to turn on. Nothing is more
      ;; annoying than a control that does nothing and does not say why.
      (when has-camera?
        [:button {:label (if camera? "Stop video" "Start video")
                  :on-click #(actions/set-camera! (not camera?))}])
      [:button {:label "Leave" :on-click #(actions/leave-call!)}]]
     (when-let [e (actions/media-error)]
       [:dim-label {:label (str "⚠ " e)}])]))

(defn- call-tile
  "One participant's picture, at the width the row worked out for it.

  `:feed` rather than `:src`: these pixels never touch the disk and never
  become a value here — the media plane hands the decoder's own buffer to
  Vidya as a pointer, and the tag paints whatever arrived last under that name.

  The height is three quarters of the width, which is the shape a camera hands
  over. Naming both keeps a portrait phone from making its tile tall enough to
  push the row off the screen — the picture is fitted inside, never stretched."
  [width key]
  (let [mine? (= (actions/local-feed) key)]
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

  Both cells this reads are what subscribe it: `actions/tiles` for who is on
  screen, and the window width so the tiles follow a window being dragged.
  Without either it would lay itself out once, on the first frame, and keep
  that shape for the rest of the call."
  []
  (let [[width rows] (actions/tile-rows)]
    [:vbox {:key :call-wall :spacing 6}
     ;; A seq, not a vector: children splice, and a vector would be read as one
     ;; more hiccup element — which an empty one is not.
     (for [[i keys] (map-indexed vector rows)]
       [:hbox {:key i :spacing 8}
        (for [key keys]
          [call-tile width key])])]))

(defn call-bar
  "The call in this channel, whatever state it is in. Always a node.

  Three cases, and the empty one matters as much as the others: a channel with
  no call must render *something* here, because the reconciler matches children
  by position and a banner that came and went would patch the message list into
  a button."
  [channel]
  [:vbox {:key :call-bar :spacing 6}
   (cond
     (actions/in-call? channel)
     [:card {}
      [:vbox {:spacing 6}
       [call-controls]
       [call-wall]]]

     ;; A call is open in this room and we are not in it.
     (actions/call-in channel)
     (let [{:keys [session-id participants title]} (actions/call-in channel)]
       [:card {}
        [:hbox {:spacing 8}
         [:label {:label (str "📞 " (or title "Call in progress")
                              (if (and participants (pos? participants))
                                (str " · " participants)
                                ""))}]
         [:button {:label "Join"
                   :on-click #(actions/join-call! channel session-id)}]]])

     ;; We are in a call, but in a different room. Say which, since the
     ;; controls are not on this screen to be found by looking.
     (actions/in-call?)
     [:dim-label {:label (str "In a call in " (:channel (actions/local-call)))}]

     :else nil)])

(defn- day-separator [day-key label]
  [:vbox {:key day-key :spacing 4 :margin 0}
   [:separator {}]
   [:dim-label {:label label}]])

(def ^:private face-size 32)

(defn- chip-gap
  "The air between two chips on a row.

  Four points is half a column, which rounds to none: in a window that is the
  gap a pair of lozenges want, and in a terminal it puts two emoji hard against
  each other and they read as one wide glyph. A column, where a column is the
  smallest thing there is."
  []
  (if @terminal? 8 4))

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
                     :on-click #(actions/open-picker! channel m)}]
         [:reaction {:key :reply
                     :emoji "↩️"
                     :size pill-size
                     :on-click #(actions/reply-to! m)}]]
        (when (actions/mine? m)
          [[:reaction {:key :edit
                       :emoji "✏️"
                       :size pill-size
                       :on-click #(actions/start-edit! channel m)}]])))

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
  (let [shown (actions/picker-emoji)
        over (max 0 (- (count shown) picker-limit))
        rows (partition-all picker-columns (take picker-limit shown))
        searching? (seq (str/trim @cells/emoji-search))]
    [:vbox {:key :picker :spacing 4}
     [:hbox {:spacing 6}
      [:entry {:key :emoji-search
               :text @cells/emoji-search
               :width-request 240
               :placeholder "Search emoji"
               :on-change #(reset! cells/emoji-search %)}]
      [:button {:label "✕" :on-click actions/close-picker!}]]
     ;; The groups are what the search box is not: a way in for someone who has
     ;; no word for what they want. Their first word is enough to tell them
     ;; apart, and is what keeps them to a couple of rows. They give way to the
     ;; search's own answer while something is typed.
     ;;
     ;; Four to a row on a phone and five in a window. The row does not wrap —
     ;; it is a row — so the count is the only thing deciding whether the last
     ;; button is on screen, and five of them ran off the right-hand edge of a
     ;; handset by about the width of the word they were trying to show.
     [:vbox {:key :groups :spacing 4}
      (when-not searching?
        (for [[i row] (map-indexed vector
                                   (partition-all (if (actions/desktop?) 5 4)
                                                  (cons nil emoji-groups)))]
          [:hbox {:key i :spacing 4}
           (for [g row]
             [:button {:key (or g "popular")
                       :label (if g (first (str/split g #" ")) "Popular")
                       :kind (if (= g @cells/emoji-group) :primary :normal)
                       :on-click #(reset! cells/emoji-group g)}])]))]
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
                         :on-click #(actions/react-from-picker! glyph)}])])
        [:dim-label {:label "No emoji by that name."}])]
     ;; What was left out, said rather than silently dropped.
     [:vbox {:key :more}
      (when (pos? over)
        [:dim-label {:label (str "and " over " more — keep typing to narrow it")}])]]))

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
  (let [h @cells/window-height]
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
  (let [w @cells/window-width]
    (if (pos? w) (min 900 (max 240 (long (* 0.95 w)))) 320)))

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
               :label (if (= nick @cells/form-nick) "you" nick)}])]])

(defn reactor-dialog
  "Who is on the reaction the pointer is resting on.

  The same dialog a face gets, for the same reason: two hover cards in two
  shapes was two things to look at and two things to keep working. Non-modal
  and no buttons, because the pointer is what is holding it open — a modal one
  would go deaf to the pill leaving and never close, and a button in it could
  never be reached.

  The message is looked up rather than carried: a pill says which message and
  which emoji it is, and the room it is in is the one being read — a pill in
  any other room is not under a pointer."
  []
  (let [{:keys [id emoji]} @cells/reaction-hover
        nicks (get (:reactions (actions/message-by-id @cells/current id)) emoji)]
    (when (seq nicks)
      [:dialog {:label "Reactions" :max-width 320 :modal false}
       [reactor-card emoji nicks]])))

(defn- reaction-row
  "What people have put on a message, under it.

  A pill carries its count and toggles: clicking one you are already on takes
  yours off, which is the same gesture that put it there. `:reaction` rather
  than a button with the emoji as its label — the chip draws the glyph from the
  Twemoji pack, in colour, where a label gets whatever the text font has."
  [channel m]
  (let [reactions (:reactions m)]
    ;; `into` and not a lazy `for` inside the vector. The pills read
    ;; `my-reaction?` — a ratom — and a ratom read while a lazy seq is being
    ;; realised somewhere other than the render is a read the component never
    ;; records, so the row went on showing what it showed before. The pictures
    ;; in `message-body` are the other place a ratom is read inside a `for`,
    ;; and are made eager for the same reason.
    (into
     [:hbox {:key :pills :spacing (chip-gap)}]
     (for [emoji (sort (keys reactions))]
       [:reaction (cond-> {:key emoji
                           :emoji emoji
                           :size pill-size
                           :count (count (get reactions emoji))
                           :mine (actions/my-reaction? m emoji)
                           :on-click #(actions/toggle-reaction! channel m emoji)}
                    ;; Where there is a pointer to ask with, resting on a pill
                    ;; says who put it there. On a phone the pill is a button
                    ;; and nothing more: there is no hover to answer.
                    (actions/desktop?)
                    ;; Nothing is hung under the pill any more: who is on a
                    ;; reaction is shown the way everything else the pointer
                    ;; asks for is shown now — the dialog at the root of the
                    ;; tree, which `reactor-dialog` builds out of
                    ;; `reaction-hover`. The pill's only job is to say where
                    ;; the pointer is.
                    (assoc :on-hover #(actions/hover-reaction! (:id m) emoji)
                           :on-unhover #(actions/unhover-reaction! (:id m) emoji)))]))))

(defn- goto-message!
  "Show message `id`, in `channel`, and say which one it was.

  Three things in a fixed order: be in the room, aim the scroll at the line,
  and mark it once it is there. `jump-to` comes off again as soon as the frame
  that scrolled has been painted — a scroll target that stays set pins the
  view and takes scrolling away from the reader — while the highlight outlives
  it, because arriving at a screenful of messages says nothing about which one
  was asked for.

  `settle` is how long that first frame is given, and `linger` how long the
  mark stays. Within a room the scrolling frame is the next one and the line
  is somewhere the reader was already looking. Crossing a room is a slower
  and a stranger arrival — the screen has to be built before there is
  anything to scroll, and what it opens on is a conversation the reader was
  not in a moment ago — so a caller that crosses one asks for more of both."
  [channel id settle linger]
  (when (and channel (not= channel @cells/current))
    (actions/open-channel! channel))
  (reset! cells/jump-to id)
  (reset! cells/highlight id)
  (actions/after! settle (fn [] (reset! cells/jump-to nil)))
  ;; The highlight only clears itself: a later jump elsewhere owns the
  ;; highlight from then on.
  (actions/after! linger (fn [] (when (= id @cells/highlight)
                                   (reset! cells/highlight nil)))))

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
   (if-let [target (actions/message-by-id channel id)]
     ;; A link, not a button: the chip is a pointer back to a line, not an
     ;; action, and a filled pill above every answer was the loudest thing in
     ;; the column.
     [:link {:label (str "↩ " (:from target) ": " (summarise target 48))
             ;; The line being answered is in the room already open, so the
             ;; next frame is the one that scrolls.
             :on-click #(goto-message! channel id 120 2000)}]
     ;; The message it answers is older than this buffer goes.
     [:dim-label {:label "↩ replying to an earlier message"}])])

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
    [:link {:key j :label value :on-click #(actions/open-url! value)}]
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

(def ^:private url-pattern #"https?://[^\s<>\"]+")

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
       ;; `avatar-path` is what wakes this row when that fetch lands.
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
         (let [src (actions/avatar-path (:actor m))]
           ;; One profile, two gestures, and no card hung under the face: the
           ;; pointer opens the dialog and the press pins it. What makes that
           ;; work is the dialog being non-modal while the pointer is what is
           ;; holding it open — see `profile-dialog`.
           [:avatar (cond-> {:label (:from m)
                             :src (or src "")
                             :size face-size
                             :on-click #(actions/profile-open! (:from m) (:actor m))}
                      (actions/desktop?)
                      (assoc :on-hover #(actions/profile-hover! (:from m) (:actor m))
                             :on-unhover #(actions/profile-unhover! (:from m))))]))
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
         [action-chips {:key :actions} @cells/current m]
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
        [reply-chip @cells/current reply-to])]
     (map-indexed (fn [j run] (run-node j run (:system? m)))
                  (text-runs (:text m)))])
   ;; And the picker, when this is the message it was opened on: under the
   ;; line it is about, where the reader is already looking.
   ;;
   ;; The id has to exist, not merely match: a line this client sent itself
   ;; has no msgid, and neither does a closed picker — so `nil = nil` was
   ;; every one of those messages opening a picker of its own at startup.
   [:vbox {:key :picker :margin-bottom 4}
    (when (and (:id m) (cells/derived-value [:reacting (:id m)] #(= (:id m) (:id @cells/reacting))))
      [emoji-picker])]
   ;; Pictures under the line that linked them. The link stays: it is what a
   ;; failed fetch, an unsupported format, or a phone with no TLS leaves you.
   (indented
    :images
    [:vbox {:key :images :spacing 4}
     (when (seq (:images m))
       ;; Eager, so each read happens during the render and is recorded — see
       ;; `reaction-row`. Each picture is read through `image-path`, which
       ;; wakes this row for its own pictures landing and not for everyone's.
       (doall
        (for [url (:images m)]
          (when-let [path (actions/image-path url)]
            [:image {:key url
                     :src path
                     :max-height (preview-height)
                     :max-width (preview-width)
                     :on-click #(reset! cells/lightbox {:path path :url url})}]))))])
   ;; Reactions go last, under whatever the message turned out to be: a
   ;; line with a picture on it is the picture, and pills between the words
   ;; and the image they introduce read as reactions to the words alone.
   ;; Nothing moves for a message with no picture — the box above it is
   ;; empty, and the pills still sit under the last line of text.
   (indented
    :reactions-row
    [:vbox {:key :reactions-row :margin-top 6}
     (when (and (:id m) (not (:system? m)) (seq (:reactions m)))
       [reaction-row @cells/current m])])])

(defn message-row
  "One message: who said it, when, what you can do to it, and the words.

  Every line names its sender, rather than the first of a run only. A run
  collapsed to one heading reads well until you answer the fourth line of it,
  and then the line quoted back has no name on it; and the actions live on the
  sender's row, which a headerless line has nowhere to put.

  Sender above the text, not beside it: a wrapping label in a horizontal row
  lays out against the row's width rather than the column's, so one long URL
  drags every line that follows it off the left edge."
  [i m jump highlight]
  (let [;; What this line is called, and what a jump is aiming at and landed
        ;; on. Handed down rather than asked for here — `message-rows` says
        ;; why this pair is not two cells like everything else on this row.
        ;;
        ;; What a jump landed on wears a surface of its own for a moment, so
        ;; the answer to "which one was I sent to" is on the screen rather
        ;; than in the reader's count of rows.
        rid (rooms/row-id m)
        highlit? (boolean (and rid (= rid highlight)))]
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
            ;; By `row-id`, not by `:id`: a line the server never named is
            ;; still a line on the screen, and a jump aimed at it has to be
            ;; able to say which one it means.
            :scroll-here (boolean (and rid (= rid jump)))}
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
         (when-let [path (actions/avatar-path (:actor m))]
           [:image {:key :picture
                    :src path
                    :max-width face-size
                    :max-height face-size}])]
        [message-body m highlit?]]
       [message-body m highlit?])]))

(defn- message-rows
  "The messages, with a heading wherever the day changes.

  A backlog can reach back weeks, and `11:04 AM` says nothing about which day
  it was. The heading is what makes the time above it mean something."
  [messages]
  ;; What a jump is aiming at and what it landed on, read here — in a render —
  ;; and handed down as two plain values.
  ;;
  ;; They were a cell per row, so that a jump woke the two rows it moved
  ;; between rather than the whole backlog, which is what `derived-value` is
  ;; for and what it still does for a hover. But a row's cell was deref'd
  ;; while this seq was realised, which is neither the row's render nor this
  ;; one, so the read was recorded against nobody: `jump-to` changed, the cells
  ;; changed, and no component was woken to put the new answer in the tree. The
  ;; prop reached the window on the render that opened the room and never
  ;; again — so a jump that needed a second frame, which is every jump into a
  ;; room that has to be built first, never got one.
  ;;
  ;; A jump is a click. Re-rendering a backlog on one is affordable in a way
  ;; that being wrong about it is not.
  (let [jump @cells/jump-to
        highlight @cells/highlight]
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
                true (conj ^{:key (or (rooms/row-id m) (str "row-" i))}
                           [message-row i m jump highlight]))))
            (range (count messages))
            messages)))

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
    (str "chat-messages-" @cells/jump-tick)
    "chat-messages"))

(def sidebar-width 320)

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

(def ^:private users-width 150)

;; How many lines the compose field is currently drawn as. The window backend
;; says so when it changes — a field with room to grow wraps a long message
;; onto a second and third line instead of sliding it sideways — and the
;; reserve below has to hear about it, since nothing in this tree is laid out
;; by anything but these counts.

(defn- messages-width
  "How wide the message list may be with the people panel beside it.

  Measured from the window rather than from what egui has left: the row is
  painted left to right, and by the time the panel is placed the list has
  already taken everything. On a wide window the chats list is holding the
  first `sidebar-width` of the window; the rest is the margins and the gap
  between the two columns."
  []
  (let [pane (- @cells/window-width (if (and (actions/wide?) (not @cells/hide-chat-list?))
                                  sidebar-width
                                  0))]
    (max 240 (- pane users-width 8 28))))

(defn- overview-row
  "One line from somewhere else: which room, who, and what — on one row.

  The room leads, because that is the whole question the strip answers. The
  name is a button for the same reason it is one in the people panel: the
  room is somewhere to go, and a line you want more of is a line you want the
  conversation behind it."
  [i m]
  [:hbox {:key i :spacing 8 :wrap false}
   ;; The room is the button, and pressing it goes to this line rather than to
   ;; the room's end: the line is what was read here and what the press was
   ;; about, and a jump that landed on the newest message instead would answer
   ;; a question nobody asked from a strip that was showing the answer.
   ;;
   ;; Every line has a name to aim at — the server's where it gave one, and
   ;; `rooms/row-id`'s where it did not — so every row here goes somewhere.
   ;;
   ;; 600ms to land and five seconds marked: the room is a room away, so the
   ;; screen it scrolls in has to be built before there is anything to scroll,
   ;; and what the reader arrives at is a conversation they were not in a
   ;; moment ago. The mark is the whole answer to "which of these was the line
   ;; I pressed", and it has to still be there when they have finished
   ;; recognising where they are.
   [:button {:label (:channel m)
             :on-click #(do (actions/leaving-for-overview!)
                            (goto-message! (:channel m) (rooms/row-id m) 600 5000))}]
   ;; And the line itself, as something to read rather than to press. It was a
   ;; link for a moment, which made the strip two things at once: a line the
   ;; server has echoed back has an id to aim at and a line this client has
   ;; just sent does not, so half the rows came out accent-coloured and half
   ;; plain, down the same list. The chip beside it is the way to the message
   ;; and is on every row either way.
   [:vbox {:key :said}
    [:dim-label {:label (str (when-let [at (:at m)] (str (clock/clock-time at) "  "))
                             (:from m) ": "
                             (preview-line (:text m)))}]]])

(defn- overview-pane
  "Every other room's recent lines in one list, newest at the top.

  A strip under the conversation rather than a screen of its own: the question
  it answers — is anything happening anywhere else — is one you ask while
  reading something, and an answer you have to leave the room for is one you
  stop asking for.

  In a window it scrolls, and the column it is in fills the height: two
  children of a column that both fill it are two halves of it, which is the
  horizontal split this is. The backlog above keeps its own scroll and its own
  place in it, so reading down here does not move the conversation.

  A terminal scrolls it too, but inside a fixed block of rows rather than a
  half of the column: the screen is already a conversation, a compose bar and
  a tab bar, and a second half-height pane would leave neither half enough
  rows to read. So the strip is as tall as `overview-lines`, `below-messages`
  reserves exactly that, and the lines past the eighth are a wheel or a page
  away instead of being cut off with nothing to say they were there."
  []
  (let [lines (actions/recent-everywhere)
        ;; The way back, and only while there is somewhere to go: the strip
        ;; is the one thing here that moves you without your having chosen a
        ;; room, so it is the one thing that owes you an undo. Gone once you
        ;; are back in that room, where it would offer to take you where you
        ;; already are.
        back (let [room @cells/overview-return]
               (when (and room (not= room @cells/current))
                 [:button {:label (str "← Back to " room)
                           :on-click actions/overview-back!}]))
        ;; The row keeps its height whether or not the way back is in it. A
        ;; button is 34 points and a caption is not, so a heading that grew
        ;; one when you jumped and lost it when you came back moved every
        ;; line under it — the strip rendering two different ways depending
        ;; on where you had been.
        heading (fn []
                  [:hbox {:key :heading :spacing 8 :wrap false :align :center}
                   [:dim-label {:label "Everywhere else"}]
                   [:vbox {:key :back}
                    (or back [:spacer {:size @chrome-row}])]])
        ;; The same heading on the same rule the conversation puts between two
        ;; days, and needed more here than there: these lines come from rooms
        ;; that were last spoken in at their own times, so a strip of them can
        ;; cross a day twice in ten rows where a single room's backlog crosses
        ;; one once a day. A clock alone would then be the only thing saying
        ;; which, and `9:40` says nothing about how long ago it was.
        rows (fn [ms]
               (if (seq ms)
                 (mapcat
                  (fn [i m]
                    (let [prev (when (pos? i) (nth ms (dec i)))
                          day (some-> (:at m) clock/day)
                          new-day? (and day (not= day (some-> (:at prev) clock/day)))]
                      (cond-> []
                        new-day?
                        (conj (day-separator (str "overview-day-" i)
                                             (clock/day-label (:at m))))
                        true
                        (conj ^{:key (str (:channel m) "-" (or (:id m) i))}
                              [overview-row i m]))))
                  (range (count ms))
                  ms)
                 [[:dim-label {:label "Nothing has been said in any other room yet."}]]))]
    (if @terminal?
      [:vbox {:key :overview :spacing 4 :margin-top 4}
       [:separator {}]
       [heading]
       ;; The same name as the window's, and for the same reason: the strip
       ;; comes and goes with a keypress, and a reader who had paged down it
       ;; should not be put back at the top for having looked away.
       (into [:scroll {:scroll-key "overview-list" :orientation :vertical
                       :spacing 4
                       ;; The reserve, exactly, and as a ceiling as well as a
                       ;; floor — see `overview-list-height`. A height-request
                       ;; on its own is a minimum: the pane took the height of
                       ;; everything in it, drew every line, and paid for the
                       ;; surplus out of the conversation above rather than
                       ;; scrolling.
                       :height-request (overview-list-height)
                       :max-height (overview-list-height)}]
             (rows lines))]
      [:vbox {:key :overview :spacing 4 :margin-top 4 :fill-height true}
       [:separator {}]
       [heading]
       ;; Named, so coming back to a conversation does not throw away where
       ;; the reader had got to in here.
       (into [:scroll {:scroll-key "overview-list" :orientation :vertical
                       :spacing 4}]
             (rows lines))])))

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
               :on-click #(actions/accept-policy! name)}]]))

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
   ;; In a slot of its own width, so an "@" and a space take the same room and
   ;; the names line up whatever mode is in front of them.
   [:vbox {:key :mode :width-request 14}
    [:dim-label {:label (if (seq prefix) prefix " ")}]]
   [:button {:label nick :on-click #(actions/open-dm! nick)}]])

(defn users-panel
  "Who is in the channel, beside the conversation.

  The list is the server's — NAMES on the way in, kept up by the joins and
  parts after it — so a channel this client has never been in has nothing to
  show, and says so rather than showing an empty column."
  [name]
  (let [people (actions/member-list name)]
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

(defn chat-screen []
  (let [name @cells/current
        buffer (get @cells/channels name)
        show-users? (and @cells/show-users? name (str/starts-with? name "#"))]
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
                      (when (= k "ctrl+end") (actions/jump-to-present!)))}
     [:hbox {:spacing 8}
      ;; The way back to the list, on a window with room for one thing at a
      ;; time. Beside the list there is nothing to go back to, so the button
      ;; goes — in a wrapper of its own, since a child that comes and goes
      ;; would otherwise renumber the row for the reconciler.
      [:vbox {:key :back}
       (when-not (actions/wide?)
         [:button {:label "← Chats" :on-click #(reset! cells/screen :chats)}])]
      ;; And the same room's other way of appearing, on a window wide enough
      ;; to have been showing both: the list folds away and the conversation
      ;; takes the whole row. Its own wrapper, since it is only offered where
      ;; there are two panes to choose between.
      ;;
      ;; One label, lit while the list is up. It used to drop to a bare "☰"
      ;; with the list showing, which made the switch two different-looking
      ;; controls in the same slot and left the reader guessing which state the
      ;; one in front of them meant. The People and Overview switches beside it
      ;; say it the other way — the label holds still and `:primary` says it is
      ;; on — so this one says it that way too.
      [:vbox {:key :fold}
       (when (actions/wide?)
         [:button {:label "☰ Chats"
                   :kind (when-not @cells/hide-chat-list? :primary)
                   :on-click actions/toggle-chat-list!}])]
      [:title {:label (or name "Chat")}]
      ;; Same wrapper trick: only in a channel, and only when there is no call
      ;; to join already — the bar below offers Join in that case, and two ways
      ;; into the same call is one more than anybody needs.
      [:vbox {:key :call}
       (when (and name
                  (str/starts-with? name "#")
                  (actions/call-available?)
                  (not (actions/call-in name))
                  (not (actions/in-call?)))
         [:button {:label "Call" :on-click #(actions/start-call! name)}])]
      ;; The people panel's switch, in a wrapper of its own for the same
      ;; reason: it is only offered in a channel, where there is a membership
      ;; to show.
      [:vbox {:key :people}
       (when (and name (str/starts-with? name "#"))
         [:button {:label (str "People " (actions/member-count name))
                   :kind (when @cells/show-users? :primary)
                   :on-click actions/toggle-users!}])]
      ;; The overview's switch. Not in a wrapper conditioned on anything: it
      ;; is about every room rather than this one, so it is offered in a DM
      ;; and in a channel alike.
      [:button {:key :overview-toggle
                :label "Overview"
                :kind (when @cells/overview? :primary)
                :on-click actions/toggle-overview!}]]
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
                 :scroll-to-bottom @cells/jump-tick
                 :on-change #(reset! cells/at-present? (= "end" %))
                 ;; The terminal's half of the same question, which arrives
                 ;; as the offset the list moved to rather than as a place.
                 ;; `scrolled!` is what turns one into the other.
                 :on-scroll actions/scrolled!}
        (if (seq (:messages buffer))
          (message-rows (:messages buffer))
          [:dim-label {:label "Nothing here yet."}])]]
      ;; The wrapper takes no height of its own: the panel inside it is the
      ;; column, and a fill-height wrapper around it would claim the strip the
      ;; compose bar sits in whether or not the panel was showing.
      [:vbox {:key :people-pane}
       (when show-users? [users-panel name])]]
     ;; Only while it is needed, and directly under the backlog: the way back
     ;; to the present belongs next to the thing that puts you there, which is
     ;; the conversation and not the overview.
     ;;
     ;; The row used to be held open by a spacer when the button was not in
     ;; it, so that the compose bar did not move when it came and went. It sat
     ;; under the backlog then, where the empty row read as the end of the
     ;; conversation. Above the strip it reads as a hole between two lists,
     ;; and there is no arguing a reader out of that — so the row is only
     ;; there when the button is, and what moves is a strip below it moving by
     ;; one row on the rare frame the reader has scrolled away from the end.
     [:vbox {:key :jump}
      (when-not @cells/at-present?
        ;; With the key beside it where there is a key: a terminal is where a
        ;; reader is least likely to reach for the mouse, and most likely to
        ;; have paged up here with the keyboard in the first place.
        [:button {:label (if @terminal?
                           "↓ Jump to present (Ctrl-End)"
                           "↓ Jump to present")
                  :on-click actions/jump-to-present!}])]
     ;; The strip, under the conversation and the way back to it: it is a
     ;; second list of messages, so it belongs with the first rather than down
     ;; among the compose bar's rows. In a wrapper of its own, since it comes
     ;; and goes.
     [:vbox {:key :overview-pane :fill-height (boolean (and @cells/overview?
                                                            (not @terminal?)))}
      (when @cells/overview? [overview-pane])]
     ;; No rule above the compose bar. The bar is already told apart from the
     ;; conversation by what it is — a framed box and a button on a strip of
     ;; air — and a line drawn over it as well was the app underlining the one
     ;; edge nobody was going to miss.
     ;; The three banners in one wrapper, at no spacing of its own. Each is a
     ;; row that is usually empty, and an empty child still costs the column
     ;; its gap — three of them stacked under the overview was two dozen
     ;; points of nothing between the strip and the compose bar. Inside, they
     ;; carry their own air only when they have something in them.
     [:vbox {:key :banners :spacing 0}
      ;; What the draft is answering, directly above where it is being typed.
      [:vbox {:key :replying}
      (when-let [target @cells/replying-to]
        [:hbox {:spacing 8}
         [:dim-label {:label (str "↩ " (:from target) ": " (summarise target 36))}]
         [:button {:label "✕" :on-click actions/cancel-reply!}]])]
      ;; And, in the same place, that the box holds a rewrite rather than
      ;; something new: the text in it is a copy of a line already on screen,
      ;; and without this Send would look like it was about to say it twice.
      [:vbox {:key :editing}
      (when @cells/editing
        [:hbox {:spacing 8}
         [:dim-label {:label "✏️ Editing your message"}]
         [:button {:label "✕" :on-click actions/cancel-edit!}]])]
      ;; The pasted picture, above the line it will go out with. Shown rather
      ;; than written into the draft: what is being sent is a picture, and a URL
      ;; dropped into the entry would be an unreadable line of text sitting in
      ;; the middle of whatever the reader was in the middle of typing.
      [:vbox {:key :attachment}
      (when-let [att @cells/attachment]
        [:hbox {:spacing 8}
         ;; Small: it is a reminder of what is attached, not the picture
         ;; itself, and the backlog above it is what the reader is here for.
         [:image {:src (:path att) :max-height 64}]
         [:dim-label {:label (if (= :uploading (:status att))
                               "Uploading…"
                               "Picture attached")}]
         [:button {:label "✕" :on-click actions/clear-attachment!}]])]]
     ;; The line and its buttons on the middle of the width rather than
     ;; against its left edge: the entry asks for a fixed width, and on a
     ;; window wider than that a left-aligned row leaves it stranded in the
     ;; corner of an otherwise empty bar. On a phone the row is as wide as the
     ;; window and centring costs nothing.
     ;; Equal air above and below, so the row sits on the middle of the strip
     ;; between the separator and the bottom edge rather than flat against it.
     ;; Above it is one of the column's gaps, where it used to be four: the
     ;; reply banner, the edit banner and the attachment share a wrapper now
     ;; and cost one between them whether or not they have anything in them.
     ;; This margin plus the window's own is what answers it underneath.
     ;; Air above the bar as well as under it. A row rather than a margin
     ;; because a terminal reads `:margin` and not `:margin-top`, and this is
     ;; the backend that needs it: the banners above are usually empty and the
     ;; strip or the last line of the conversation sat directly on the field,
     ;; so a message being typed read as one more message in the room.
     (when @terminal? [:spacer {:key :compose-gap :size @chrome-row}])
     [:hbox {:spacing 8 :align :center :margin-bottom 12}
      ;; narrow enough that Send keeps its place on a phone-width row
      ;; A picture is pasted where everything else is typed: Ctrl+V. The field
      ;; answers a paste of text with the text, and one of a picture reaches
      ;; `:on-paste-empty` — a keystroke the field had nothing to put in
      ;; itself, which is exactly the one that means "the clipboard has
      ;; something else on it".
      ;; And the same picture chosen rather than pasted, for a phone — which has
      ;; no Ctrl+V, and no clipboard of pictures to read if it had.
      ;; In a window, a picture on a Delight 2 tile (src/frq/icons, on the
      ;; geometry delight-icons generates its tiles with): grey frame, dark
      ;; square, cream glyph — where the emoji was a colour photo that matched
      ;; nothing else in the bar. Its path is read from the working directory,
      ;; which is the tree under `just run` and `just cosmic` and the store
      ;; copy under the flake's launcher. A terminal has no pixels to put
      ;; it in, and an APK carries no src/ to read it from — both keep the glyph.
      ;; `:jolt` and not `desktop?`: the tile is a file read out of the working
      ;; directory, which is the source tree jolt runs from. Flutter's desktop
      ;; target is a window with a pointer like libcosmic's — `desktop?` is
      ;; true there now — but it is launched from `flutter/` and bundles no
      ;; src/, so it keeps the glyph the APK keeps.
      (if #?(:jolt (and (actions/desktop?) (not @terminal?)) :cljd false)
        [:image {:src "src/frq/icons/insert-image.png"
                 :size [36 36]
                 ;; On the middle of the field rather than the top of it: the
                 ;; box grows downwards as a message is typed, and a button
                 ;; pinned to its first row drifts away from the thing it acts
                 ;; on. Read by the terminal, where the row can be several
                 ;; cells tall; a window's backends ignore it.
                 :valign :center
                 ;; for a backend that sizes a picture by its bounds instead
                 :max-width 36
                 :max-height 36
                 :on-click actions/open-image-picker!}]
        [:button {:label "🖼" :valign :center :on-click actions/open-image-picker!}])
      ;; In a terminal the row is the width of the screen, so the field takes
      ;; the surplus rather than scrolling one line sideways — and it is as
      ;; tall as what has been typed into it. Three rows were kept for it
      ;; always, empty almost always, drawn as two ruled boxes under the one
      ;; being typed in: rows spent on a paragraph nobody had written, taken
      ;; off the conversation above. Now the box is a line until there is a
      ;; second line to put in it.
      [:entry {:key :draft
               :text @cells/draft
               :width-request 260
               ;; Always, not only in a terminal. A window is the case that
               ;; needs it more: 260 points is most of a phone's row and a
               ;; third of a pane's, and the field sat stranded in the middle
               ;; of the bar with the rest of it empty. The number stays as
               ;; the minimum it always was.
               :hexpand true
               :rows (if @terminal? (terminal-draft-rows) 1)
               ;; The field starts as one line and takes another every time
               ;; the message stops fitting, up to five — past which it
               ;; scrolls, keeping the caret in view. A paragraph typed into a
               ;; one-line box was readable a dozen characters at a time,
               ;; which is not how anybody writes one.
               ;;
               ;; A window grows itself and says so through `:on-rows`; a
               ;; terminal is given the height `terminal-draft-rows` counted,
               ;; which is the same ceiling reached the other way round.
               :max-rows draft-max-rows
               :on-rows #(reset! draft-rows %)
               :placeholder "Message"
               :on-change #(reset! cells/draft %)
               :on-paste-empty actions/paste-image!
               :on-activate actions/send-draft!}]
      [:button {:label "Send" :kind :primary :valign :center
                :on-click actions/send-draft!}]]]))
