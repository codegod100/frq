(ns frq.screens.app
  "The screens as one app: which one is showing, the split view that shows two
  at once, and the three that sit over the top of whichever it is.

  The last of `frq.app` to move, and the piece that makes the rest of it
  reachable — a phone was switching screens by hand before this, because the
  thing that decides had not been shared yet.

  `profile-screen`, `lightbox-screen` and `image-picker-screen` come with it
  because `app` is what shows them. All three lean on things a phone does not
  have yet — a picture cache, a profile fetch, a filesystem to browse — and
  all three ask `frq.actions` for them, so what a phone gets is the shape they
  take when the answer is nil."
  (:require [clojure.string :as str]
            [frq.actions :as actions]
            [frq.cells :as cells]
            [frq.metrics :refer [terminal?]]
            [frq.rooms :as rooms]
            [frq.screens.chat :refer [chat-screen emoji-picker reactor-dialog
                                      sidebar-width]]
            [frq.screens.chats :refer [chats-screen conversation-row tab-bar]]
            [frq.screens.connect :refer [connect-screen error-note]]
            [frq.screens.settings :refer [discover-screen settings-screen
                                          tab-screen]]))

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
  (let [dir @cells/image-picker
        {:keys [dirs files]} (actions/picker-entries dir)
        up (actions/parent-dir dir)]
    [:vbox {:spacing 8 :margin 12}
     [:hbox {:spacing 8}
      [:button {:label "← Back" :on-click actions/close-image-picker!}]
      [:title {:label "Send a picture"}]]
     [:dim-label {:label (str dir)}]
     [error-note]
     ;; The places worth starting from, always in reach: browsing into a corner
     ;; of the filesystem should not cost the way back to the pictures folder.
     [:hbox {:key :roots :spacing 6}
      (for [root (actions/picker-roots)]
        [:button {:key root
                  :label (or (last (str/split root #"/")) root)
                  :kind (if (= root dir) :primary :default)
                  :on-click #(actions/browse! root)}])]
     [:separator {}]
     [:scroll {:scroll-key "image-picker"
               :orientation :vertical
               :reserve 40}
      [:vbox {:spacing 6}
       [:vbox {:key :up}
        (when up
          [:button {:label "⬆ Up" :on-click #(actions/browse! up)}])]
       [:vbox {:key :dirs :spacing 4}
        (for [d dirs]
          [:button {:key d
                    :label (str "📁 " (last (str/split d #"/")))
                    :on-click #(actions/browse! d)}])]
       ;; The picture itself is the button: a filename is not what anyone is
       ;; choosing between, and a thumbnail answers "is this the one" in a way
       ;; no name does.
       [:vbox {:key :files :spacing 6}
        (for [f files]
          [:hbox {:key f :spacing 8}
           [:image {:src f :max-height 72 :on-click #(actions/pick-image! f)}]
           [:button {:label (last (str/split f #"/"))
                     :on-click #(actions/pick-image! f)}]])]
       [:vbox {:key :empty}
        (when (and (empty? dirs) (empty? files))
          [:dim-label {:label "No pictures here that this app can read."}])]]]]))

;; What the people panel asks for, and what the conversation beside it has to
;; be told to leave. A column with `:fill-height` and no width takes the whole
;; row — so the panel is only ever on screen if the message list is given a
;; width that stops short of it.

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
  (let [{:keys [path]} @cells/lightbox]
    [:vbox {:spacing 4 :margin 4}
     [:hbox {:spacing 8}
      [:button {:label "← Back" :on-click #(reset! cells/lightbox nil)}]]
     [:image {:src path :fit true :on-click #(reset! cells/lightbox nil)}]]))

(defn- profile-dialog
  "Who someone is, as libcosmic's own dialog: centred over the window, with
  what you were reading dimmed behind it rather than replaced.

  The window can do this and the terminal cannot, which is the whole reason
  there are two of these. `profile-screen` below is the terminal's, and says
  why it is a screen.

  Both buttons are always here, the Bluesky one insensitive until there is a
  profile to open: a dialog whose second button appears a moment after it
  opens is a dialog that moves under the pointer, and the fetch lands whenever
  it lands.

  Who it is about comes from either of two places, and that — with the
  modality below — is the whole of what hovering and pressing a face do
  differently. Resting on one sets `hovering`, which the pointer takes away
  again when it leaves; pressing one sets `viewing`, which nothing takes away
  but Close. `viewing` is read first, so a pinned profile is not swapped out
  from under the reader by a face the pointer crosses on the way to it.

  And a dialog the pointer is holding open is not modal. A modal one makes
  the window underneath it deaf — libcosmic wraps the app in a popover that
  hands its content an `Unavailable` cursor while a popup is up — so the face
  that opened it never hears the pointer leave, and what a hover opened could
  never close itself. Non-modal, the face keeps hearing, and moving away shuts
  it. A pinned one is modal, which is what being pinned means: it is the thing
  on the screen until it is dismissed."
  []
  (let [pinned? (some? (actions/viewing))
        {:keys [nick actor]} (or (actions/viewing) (actions/hovering))
        _ (actions/profile-tick)
        _ (actions/media-tick)
        pr (actions/profile-entry actor)
        ready? (= :ready (:status pr))
        display (or (:display-name pr) nick)
        url (when ready? (actions/profile-web-url pr))]
    [:dialog {:label display :max-width 520 :modal pinned?
              :on-hover actions/profile-enter-dialog!
              :on-unhover actions/profile-leave-dialog!}
     ;; The body is the screen's card without its heading: the dialog's own
     ;; title is the name now, so repeating it under the picture is a line
     ;; that says nothing.
     [:vbox {:key :body :spacing 8}
      [:hbox {:spacing 12}
       [:avatar {:label nick
                 :src (or (actions/avatar-ready actor) "")
                 :size 72}]
       [:vbox {:spacing 2}
        [:vbox {:key :nick}
         (when (not= display nick) [:dim-label {:label nick}])]
        [:vbox {:key :handle}
         (when-let [h (and ready? (not-empty (or (:handle pr) "")))]
           [:label {:label (str "@" h)}])]
        [:vbox {:key :did}
         (when-let [did (:did pr)] [:dim-label {:label did}])]]]
      [:vbox {:key :bio :spacing 2}
       (when-let [bio (and ready? (:description pr))]
         (for [[i line] (map-indexed vector (str/split-lines (actions/profile-truncate bio 600)))]
           [:label {:key i :label line}]))]
      [:vbox {:key :stats}
       (when-let [line (and ready? (actions/profile-stats-line pr))]
         [:dim-label {:label line}])]
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
]
     ;; `slot` is where libcosmic puts a button: the two actions go to the
     ;; foot of the dialog, and anything else here would be another control
     ;; stacked in the body.
     ;;
     ;; Both are here whether the profile is pinned or only hovered. They were
     ;; hidden while hovering, back when a hover could not be walked into: the
     ;; dialog reports its own pointer now, so moving towards a button in it
     ;; keeps it open instead of closing it, and a button you can reach is a
     ;; button worth drawing.
     [:button {:key :close :slot "primary"
               :label (if pinned? "Close" "Dismiss")
               :on-click actions/profile-dismiss!}]
     [:button {:key :web :slot "secondary" :label "Bluesky ↗"
               :sensitive (boolean url)
               :on-click #(when url (actions/open-url! url))}]]))

(defn profile-screen
  "Who someone is: sleek's peer profile modal, as a screen.

  A screen rather than a layer for the same reason the lightbox is one — the
  tree backend paints in a single layer, with no z-order to hang a modal from.
  So the back row does what sleek's ✕ and backdrop did.

  The picture is the same cached file the chat column draws, at a size worth
  looking at; the bio is split into a label a line, so a bio that was written
  as several lines is still several lines here."
  []
  (let [{:keys [nick actor]} (actions/viewing)
        ;; Reading both ticks subscribes this screen to the two fetches it is
        ;; waiting on: the profile itself, and the picture on it.
        _ (actions/profile-tick)
        _ (actions/media-tick)
        pr (actions/profile-entry actor)
        ready? (= :ready (:status pr))
        display (or (:display-name pr) nick)
        url (when ready? (actions/profile-web-url pr))]
    [:page {:max-width 520}
     [:hbox {:spacing 8}
      [:button {:label "← Back" :on-click actions/profile-close!}]]
     [:card {}
      [:hbox {:spacing 12}
       [:avatar {:label nick
                 :src (or (actions/avatar-ready actor) "")
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
         (for [[i line] (map-indexed vector (str/split-lines (actions/profile-truncate bio 600)))]
           [:label {:key i :label line}]))]
      [:vbox {:key :stats}
       (when-let [line (and ready? (actions/profile-stats-line pr))]
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
                   :on-click #(actions/open-url! url)}])]]]))

(defn- no-chat-pane
  "What fills the second pane before a conversation has been picked. The pane
  is there either way — a list that widened into two columns and back again as
  channels were opened would be a worse answer than an empty half."
  []
  [:vbox {:spacing 8 :margin 12}
   [:title {:label "frq"}]
   ;; With the list folded away there is nothing on the left to pick from, and
   ;; no conversation here carrying the switch that would bring it back — so
   ;; this pane carries it instead. Without that the reader who hid the list
   ;; and then closed the last room has put the app away, not the list.
   (if @cells/hide-chat-list?
     [:card {}
      [:dim-label {:label "The chats list is hidden."}]
      [:button {:label "☰ Chats" :kind :primary
                :on-click actions/toggle-chat-list!}]]
     [:card {} [:dim-label {:label "Pick a conversation on the left."}]])])

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
  ;; And the row itself takes the window, for the reason each narrow root
  ;; gives: a backend that sizes a box by what is in it hands two panes that
  ;; both asked for the rest of the screen the height of the taller one's
  ;; contents. Marking the children alone is not enough — what they fill is
  ;; whatever the row got.
  [:hbox {:spacing 0 :wrap false :fill-height true}
   ;; :expand :cross so the width-request is the width. Both panes fill the
   ;; height, and a pane that fills the height is also told to take a share
   ;; of the row's spare WIDTH — which two panes split between them, so the
   ;; list came out half the window with its cards clipped at the fold and
   ;; the conversation squeezed beside it. Down a row, :cross is the vertical
   ;; axis alone: the height without the share. The conversation keeps
   ;; :fill-height and so keeps the slack, which is what the note above says
   ;; it takes.
   ;; The list pane, when the reader has not put it away. Hidden, the wrapper
   ;; stays and empties: a child that vanished would renumber the row for the
   ;; reconciler and take the conversation's scroll position with it every
   ;; time the list was toggled — the same trick the people panel plays.
   ;; Empty, it asks for nothing: no width and no `:fill-height`, because a
   ;; column that fills the height is also a column that is there, and a
   ;; 320-point hole where the list was is not hiding it.
   (if @cells/hide-chat-list?
     [:vbox {:key :list}]
     [:vbox {:key :list :width-request sidebar-width :fill-height true
             :expand :cross}
      [chats-screen]])
   [:vbox {:key :chat :fill-height true}
    (if @cells/current
      [chat-screen]
      [no-chat-pane])]])

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
  ;; And the dialog beside them all rather than instead of one of them. A
  ;; `dialog` node is not painted where it stands — the window backend hands
  ;; it to libcosmic, which puts it over the middle of the window with what is
  ;; behind it dimmed — so the screen under it keeps its place in the tree,
  ;; and its scroll position with it. The wrapper is always here and only its
  ;; child comes and goes, for the reason every other wrapper in this file
  ;; gives: a child that appeared and vanished would renumber the root.
  ;;
  ;; The terminal has no such thing, and a `dialog` tag it has not grown would
  ;; paint its contents inline at the bottom of the screen. So there it stays
  ;; a screen you go to and come back from, which is `profile-screen`.
  [:vbox {:key :root :fill-height true}
   ;; One dialog at a time, and a pinned profile outranks both pointers: it is
   ;; the only one of the three that was asked for by a press rather than by
   ;; where the pointer happens to be resting.
   [:vbox {:key :dialog}
    (when-not @terminal?
      (cond
        (or (actions/viewing) (actions/hovering)) [profile-dialog]
        @cells/reaction-hover [reactor-dialog]))]
   (cond
    @cells/lightbox [:vbox {:key :screen-lightbox} [lightbox-screen]]
    (and @terminal? (actions/viewing))
    [:vbox {:key :screen-profile} [profile-screen]]
    @cells/image-picker [:vbox {:key :screen-picker} [image-picker-screen]]
    ;; Wide enough for both, and on one of the two screens that are halves of
    ;; the same thing: the list and the conversation it opens. Discover and
    ;; settings stay whole screens — they are somewhere else, not the other
    ;; half of here.
    (and (actions/wide?) (contains? #{:chats :chat} @cells/screen))
    [:vbox {:key :screen-split} [split-screen]]
    :else (case @cells/screen
            :connect [:vbox {:key :screen-connect} [connect-screen]]
            :chat [:vbox {:key :screen-chat} [chat-screen]]
            :discover [:vbox {:key :screen-discover} [discover-screen]]
            :settings [:vbox {:key :screen-settings} [settings-screen]]
            [:vbox {:key :screen-chats} [chats-screen]]))])
