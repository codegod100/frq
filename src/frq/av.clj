(ns frq.av
  "Calls: the signaling, in jolt, and a handle on the media plane, which is not.

  A freeq call has two halves. The one that is written here is *signaling* —
  `+freeq.at/av-start`, `av-join` and `av-leave` go out as TAGMSGs and the
  server broadcasts `+freeq.at/av-state` back, which is IRC and nothing more,
  so it is written in the language the rest of the client is written in.

  The other half is audio and video over MoQ, and it used to be `libjoltmoq`
  — three thousand lines of Rust behind a C ABI. It is `frq.av.plane` now:
  MoQ over QUIC from `libmoq_ffi`, Opus from libopus, H.264 from openh264,
  and the camera and sound devices from V4L2 and ALSA, all bound directly.
  This namespace is the whole of what frq says to it, and what it says has
  barely changed — the plane was built to joltmoq's shape on purpose.

  Two rules come from that side and shape everything here:

  * **Nothing calls back.** Status and video are *polled* — `pump!` drains both
    and is called from a timer, which glimmer runs on the loop thread.
  * **A video frame is borrowed**, valid only until the next poll. `pump!`
    hands each one to Vidya as it arrives and never keeps one, which is also
    why a frame never becomes a jolt value: it goes from the decoder's buffer
    to the texture as a pointer, and is never copied on this side at all.

  Both still hold, and for the same reasons — the plane is pumped because a
  blocking foreign call would pin glimmer's loop thread, and it hands out
  borrowed pointers because a frame at thirty a second cannot afford a copy."
  (:require [clojure.string :as str]
            [glimmer.ratom :as r :refer [atom]]
            [glimmer-vidya.core :as vidya]
            [frq.irc :as irc]
            [frq.av.dial :as dial]
            [frq.av.plane :as plane]
            [frq.capture.alsa :as alsa]
            [frq.capture.v4l2 :as v4l2]))

;; --- the media plane ---------------------------------------------------------
;; `frq.av.plane`, where this used to be twenty-five `joltmoq_*` symbols.
;; The shape is deliberately the same one — start, stop, poll status, poll
;; frames — because that is what let the plane be swapped in underneath this
;; file rather than through it.

(def ^:private status-live :live)
(def ^:private status-ended :ended)
(def ^:private status-failed :failed)

(defonce ^:private media-plane
  ;; Whether the media plane can run here at all, asked once. It cannot on
  ;; the phone: the plane is V4L2 and ALSA, and Android has neither — the
  ;; camera is Camera2 through JNI and the audio is AAudio. A client that
  ;; cannot make calls is still a client, so the answer gates the call
  ;; surface rather than ending the run.
  ;;
  ;; Asked by looking for a sound device rather than by loading anything:
  ;; every library the plane needs is declared in deps.edn and already
  ;; resolved by the time this runs, so the question is not "is the code
  ;; here" but "is there anything for it to talk to".
  (delay
    (try (boolean (seq (alsa/devices :playback)))
         (catch Exception _ false))))

(defn available?
  "Whether calls can happen here at all."
  []
  @media-plane)

(defn- pref [s] (or s ""))

(defn live? [] (plane/live?))

(defn can-dial?
  "Whether dialling this server is worth attempting. A remote SFU with no token
  accepts the connection and closes it, and the MoQ client then retries in a
  tight loop that looks exactly like a hang."
  [server jwt]
  (dial/can-dial? server jwt))

(defn sfu-url
  "The SFU to dial for this server, or nil when the server is not one a URL can
  be made of."
  [server jwt instance]
  (dial/sfu-url server jwt instance))

(defn new-instance
  "A per-device call instance id. Two devices signed in as the same person need
  different ones, or their broadcast paths collide."
  []
  (dial/new-instance))

;; --- devices -----------------------------------------------------------------
;; Where joltmoq answered a tab-separated string that this file parsed, the
;; bindings answer the maps directly. The shape the UI reads is unchanged:
;; {:id :name :default?}.

(defn cameras []      (try (v4l2/devices) (catch Exception _ [])))
(defn microphones []  (try (alsa/devices :capture) (catch Exception _ [])))
(defn speakers []     (try (alsa/devices :playback) (catch Exception _ [])))

;; --- the signaling tags ------------------------------------------------------
;; Every one of these is a TAGMSG to the channel. The server answers with an
;; `+freeq.at/av-state` broadcast, which is what actually moves this client's
;; state — nothing below assumes a request succeeded.

(defn start-tags
  "Open a call on this channel."
  [instance title]
  (cond-> {"+freeq.at/av-start" ""
           "+freeq.at/av-instance" instance}
    (seq title) (assoc "+freeq.at/av-title" title)))

(defn join-tags
  "Join the call already open on this channel."
  [session-id instance]
  {"+freeq.at/av-join" ""
   "+freeq.at/av-id" session-id
   "+freeq.at/av-instance" instance})

(defn leave-tags
  [session-id instance]
  {"+freeq.at/av-leave" ""
   "+freeq.at/av-id" session-id
   "+freeq.at/av-instance" instance})

(defn parse-state
  "An `+freeq.at/av-state` broadcast, or nil for any other TAGMSG.

  Safe to apply to every TAGMSG that arrives: a reaction answers nil."
  [tags]
  (let [action (irc/tag-value tags "+freeq.at/av-state")]
    (when (contains? #{"started" "joined" "left" "ended"} action)
      {:action (keyword action)
       :session-id (or (irc/tag-value tags "+freeq.at/av-id") "")
       :actor (irc/tag-value tags "+freeq.at/av-actor")
       :participants (when-let [p (irc/tag-value tags "+freeq.at/av-participants")]
                       (try (Integer/parseInt p) (catch Exception _ nil)))
       :title (let [t (irc/tag-value tags "+freeq.at/av-title")]
                (when (seq t) t))})))

(defn state-message
  "The system line a state change is worth showing as."
  [{:keys [action actor participants title]}]
  (let [who (or actor "someone")
        n (if participants (str " · " participants " in call") "")]
    (case action
      :started (str "Call started by " who
                    (if (seq title) (str " “" title "”") "")
                    n)
      :joined (str who " joined the call" n)
      :left (str who " left the call" n)
      :ended (str "Call ended" n)
      "")))

;; --- what the UI reads -------------------------------------------------------

;; channel -> {:session-id :title :participants :last-actor}. What the server
;; says is happening in a room, whether or not we are in it: this is what puts
;; a "join the call" banner above a channel nobody here has joined.
(defonce channel-calls (atom {}))

;; nil, or the call this device is in. `:media` is how far the other half has
;; got: :dialling until the plane says otherwise, then :live or :failed.
(defonce local-call (atom nil))

;; The last thing the media plane failed with, for the line under the controls.
(defonce media-error (atom nil))

;; What to do when this device stops being in a call without having asked to.
;;
;; The media plane failing is not the server hearing about it: freeq counts a
;; participant until an `av-leave` says otherwise. Dropping out quietly leaves
;; a ghost in the room, and pressing Join again adds a second one — which is
;; how a channel ends up reporting seven people in a call with two.
;;
;; `frq.state` puts the TAGMSG here. This namespace cannot send one itself
;; without depending on the client that owns the connection.
(defonce on-dropped (atom nil))

;; SFU tokens, by session id.
;;
;; The server mints one when you join, and does not necessarily mint another
;; when you join the same call again — so a client that forgets it on the way
;; out has nothing to dial with on the way back in, and rejoining signals
;; correctly and then sits there with no video. Kept past the call for exactly
;; that, and overwritten whenever a fresh one arrives.
(defonce ^:private session-tokens (atom {}))

;; Feeds pushed to Vidya, so the ones that stop can be dropped again. Without
;; this the last frame of someone who left hangs on the wall for the rest of
;; the call.
(defonce ^:private painted-feeds (atom #{}))

;; Who has a picture, in the order they should be drawn.
;;
;; A cell rather than a question asked at render time, and that is the whole
;; point: glimmer re-renders a component when a ratom it read has changed, so a
;; view that asked the media plane directly would render once with nobody on
;; screen and never be told that someone had appeared. The frames would arrive,
;; be handed to Vidya, and paint into no node at all.
(defonce feeds (atom []))

;; The window's width in points, so a tile can be a share of it rather than a
;; number somebody picked. A cell for the same reason `feeds` is one: a
;; component that asked the backend at render time would lay itself out once,
;; on the first frame, and keep that shape however the window was dragged.
(defonce window-width (atom 0))
(defonce window-height (atom 0))

;; The self-view is keyed this way by the media plane; the UI wants to know
;; which tile is its own, to label it and to mirror nothing else.
(def local-feed "__local__")

(declare stop-media!)

(defn call-in [channel] (get @channel-calls channel))

(defn in-call?
  ([] (some? @local-call))
  ([channel] (= channel (:channel @local-call))))

(defn apply-state!
  "Fold an `+freeq.at/av-state` broadcast into what we know about `channel`.

  The server is the authority on who is in a call, so this only writes what it
  was told. Ending clears the room; anything else updates the tally in place,
  because a `left` that omits the count should not reset it to nothing."
  [channel st]
  (let [{:keys [action session-id actor participants title]} st]
    (if (= :ended action)
      (swap! channel-calls dissoc channel)
      (swap! channel-calls update channel
             (fn [c]
               (cond-> (or c {:participants 0})
                 true (assoc :session-id session-id)
                 participants (assoc :participants participants)
                 ;; A `started` with no count is one person: whoever started it.
                 (and (nil? participants)
                      (= :started action)
                      (zero? (:participants (or c {:participants 0}))))
                 (assoc :participants 1)
                 actor (assoc :last-actor actor)
                 title (assoc :title title)))))
    ;; A call we are in that has ended is one we are no longer in, whoever
    ;; ended it. Leaving the local call set would leave the controls up over
    ;; a session the SFU has already forgotten.
    (when (and (= :ended action) (in-call? channel))
      (stop-media!))
    ;; The server agreeing we are in the call is the other moment worth
    ;; dialling on. A join we opened optimistically has no session id until
    ;; this arrives — and a *re*join often brings no token with it, because the
    ;; server already minted one for this session and does not mint a second.
    (when (and (not= :ended action) (in-call? channel))
      (when (and (seq session-id) (str/blank? (:session-id @local-call)))
        (swap! local-call assoc :session-id session-id))
      true)))

;; --- the media plane, as this client uses it ---------------------------------

(defn- drop-feeds!
  "Stop painting every feed we have been pushing."
  []
  (doseq [k @painted-feeds] (vidya/frame-drop! k))
  (reset! painted-feeds #{})
  (reset! feeds []))

(defn stop-media!
  "Leave the media plane and forget the call, telling nobody.

  For the two cases where the server already knows: it ended the call itself,
  or the caller is about to send an `av-leave` of its own. Anything else wants
  `dropped!`, or freeq goes on counting a participant who is not there."
  []
  (plane/stop!)
  (drop-feeds!)
  (reset! feeds [])
  (reset! local-call nil)
  (reset! media-error nil))

(defn dropped!
  "We are out of the call and did not ask to be — the media plane failed, or
  the transport went away under it.

  Tells whoever registered `on-dropped` first, while the session id and
  instance it needs are still here to be read, and only then forgets them."
  []
  (when-let [announce @on-dropped]
    (when-let [call @local-call]
      (try (announce call) (catch Exception _ nil))))
  (stop-media!))

(declare try-start-media!)

(defn- start-media!
  "Dial the SFU for the call we have already joined over IRC.

  Called once the server has minted a token for us, not when we asked to join:
  a remote SFU refuses a connection without one and the MoQ client then retries
  in a loop that looks exactly like a hang."
  [server]
  (when-let [{:keys [session-id instance token muted? speaker-muted? camera?
                     camera-id mic-id speaker-id nick]} @local-call]
    (if-let [url (sfu-url server token instance)]
      (do
        (swap! local-call assoc :media :dialling)
        (reset! media-error nil)
        ;; Fire and forget: the connect is a QUIC handshake and waiting for
        ;; it here would freeze the window for as long as it took — thirty
        ;; seconds when the SFU is not there. `pump!` finishes it and
        ;; `pump-status!` below reports what happened, which is exactly
        ;; what this did when the waiting was joltmoq's to do.
        (try
          (plane/dial! {:url url
                        :path (str "/" instance)
                        :camera-device (when camera? camera-id)
                        :mic-device    (when-not muted? mic-id)
                        :speaker-device (when-not speaker-muted? speaker-id)
                        :camera? camera?
                        :muted?  muted?})
          (catch Exception e
            (swap! local-call assoc :media :failed)
            (reset! media-error (or (ex-message e)
                                    "could not start the media plane")))))
      (do (swap! local-call assoc :media :failed)
          (reset! media-error (str "no SFU for " server))))))

(defn try-start-media!
  "Dial the SFU if there is a call to dial for, and we are not already on it.

  Called from every signal that might mean the call is ready — the server
  agreeing we joined, a token arriving, a rejoin — because none of them is
  reliably the one that comes last. What makes that safe is the two guards:
  `can-dial?` refuses a remote SFU with no token rather than retrying in a
  loop that looks like a hang, and a call already up or on its way is left
  alone rather than re-dialled."
  [server]
  (when-let [{:keys [session-id token media]} @local-call]
    (when (and (available?)
               (seq session-id)
               (not (contains? #{:dialling :live} media))
               (can-dial? server token))
      (start-media! server))))

(defn apply-token!
  "The server minted us an SFU token — remember it, and dial.

  This arrives as a TAGMSG directed at our own nick rather than at the channel,
  so the buffer it came in on says nothing about which call it is for; the
  session id in the tag does. One naming a different session than ours is not
  ours.

  Remembered past the end of the call, because the server does not always mint
  a second one when you rejoin the same session."
  [server session-id token]
  (when-let [lc @local-call]
    (when (or (str/blank? session-id)
              (str/blank? (:session-id lc))
              (= session-id (:session-id lc)))
      (let [sid (if (seq session-id) session-id (:session-id lc))]
        (when (seq sid)
          (swap! session-tokens assoc sid token))
        (swap! local-call
               #(-> %
                    (assoc :token token :awaiting-start? false)
                    (cond-> (seq sid) (assoc :session-id sid)))))
      (try-start-media! server))))

(defn begin!
  "Record that this device is joining `channel`, before the server has agreed.

  Optimistic on purpose: the controls appear on the press rather than a round
  trip later. `:awaiting-start?` is what a start that has not been answered yet
  looks like, and is how a collision is recognised as ours."
  [{:keys [channel session-id nick muted? speaker-muted? camera?
           camera-id mic-id speaker-id]}]
  (let [instance (new-instance)]
    (reset! media-error nil)
    (reset! local-call
            {:channel channel
             :session-id (or session-id "")
             :instance instance
             :nick nick
             ;; What we were given last time we were in this call, if
             ;; anything. A rejoin the server answers with no new token
             ;; still has something to dial with.
             :token (get @session-tokens (or session-id ""))
             :awaiting-start? (str/blank? (or session-id ""))
             :muted? (boolean muted?)
             :speaker-muted? (boolean speaker-muted?)
             :camera? (boolean camera?)
             :camera-id camera-id
             :mic-id mic-id
             :speaker-id speaker-id
             :media :waiting})
    instance))

;; --- controls ----------------------------------------------------------------
;; Each writes the cell the UI reads *and* tells the media plane, so a control
;; answers on the press rather than a frame later. Muting the microphone and
;; muting the speaker are deliberately separate: deafening yourself still lets
;; peers hear you.

(defn set-muted! [muted?]
  (swap! local-call assoc :muted? muted?)
  (plane/set-muted! muted?))

(defn set-speaker-muted! [muted?]
  (swap! local-call assoc :speaker-muted? muted?)
  (plane/set-speaker-muted! muted?))

(defn set-camera! [on?]
  (swap! local-call assoc :camera? on?)
  (plane/set-camera! on?)
  ;; The tile goes when the camera does: the plane stops publishing, so no
  ;; frame arrives to replace the last one.
  (when-not on?
    (vidya/frame-drop! local-feed)
    (swap! painted-feeds disj local-feed)))

;; Switching a device mid-call reopens it, which the plane can only do by
;; going round again — there is no V4L2 ioctl for "become a different
;; camera". The id is recorded either way, so a call started afterwards
;; uses it even where a live switch is not offered yet.

(defn set-camera-device! [id]
  (swap! local-call assoc :camera-id id)
  (plane/set-camera-device! id))

(defn set-mic-device! [id]
  (swap! local-call assoc :mic-id id)
  (plane/set-mic-device! id))

(defn set-speaker-device! [id]
  (swap! local-call assoc :speaker-id id)
  (plane/set-speaker-device! id))

;; --- the pump ----------------------------------------------------------------

(defn- pump-status!
  "Drain what the media plane has learned since the last frame.

  A drained QUEUE rather than a code per call, which is what the plane
  answers — but the loop is the same shape and for the same reason: a call
  can fail and end between two pumps, and reading only the latest state
  would show the wrong one."
  []
  (doseq [{:keys [code text has-camera? has-mic?]} (plane/poll-status!)]
    (cond
      (= code status-live)
      (swap! local-call #(when % (assoc % :media :live
                                          :has-camera? (boolean has-camera?)
                                          :has-mic? (boolean has-mic?))))

      ;; Both of these are the call ending underneath us rather than at
      ;; our request, so both have to be announced. A failure keeps the
      ;; local call up afterwards so the reason stays on screen — but the
      ;; server is told either way, because we are no longer in the call
      ;; whether or not the person has read why yet.
      (= code status-ended)
      (dropped!)

      (= code status-failed)
      (let [call @local-call]
        (when-let [announce @on-dropped]
          (when call (try (announce call) (catch Exception _ nil))))
        (reset! media-error text)
        (swap! local-call #(when % (assoc % :media :failed)))))))

(defn- pump-frames!
  "Hand every new frame straight to Vidya.

  The pointer is borrowed until the next poll, so it is used and dropped inside
  this loop and never held. Nothing is copied on this side: the pixels go from
  the decoder's own buffer to a texture without becoming a jolt value at all,
  which is the only way a call at thirty frames a second is affordable here.

  Several frames at once now, where joltmoq answered one per poll. That is
  safe because the plane keeps a decoder PER PEER: one shared between them
  would make every pointer here alias the last picture decoded."
  []
  (doseq [{:keys [key w h rgba]} (plane/poll-frames!)]
    (when (and (seq key) (pos? w) (pos? h) rgba)
      (vidya/frame-rgba! key w h rgba)
      (swap! painted-feeds conj key))))

(defn- order-feeds
  "Everyone with a picture, the self-view last.

  Last because it is the one whose subject the person can already see, so it
  belongs where it will not push a face they are talking to off the row."
  [keys]
  (let [mine (filter #(= local-feed %) keys)
        others (sort (remove #(= local-feed %) keys))]
    (vec (concat others mine))))

(defn- pump-feeds!
  "Reconcile who has a picture: drop the tiles of anyone who has stopped, and
  publish the list for the view to render from.

  The cell is only written when the set has actually changed. Writing it every
  frame would re-render the call wall sixty times a second to say the same
  thing, and every `:image` node under it would be rebuilt around a texture
  that was fine where it was."
  []
  (let [live (plane/feed-keys)]
    (doseq [k (remove live @painted-feeds)]
      (vidya/frame-drop! k)
      (swap! painted-feeds disj k))
    (let [ordered (order-feeds live)]
      (when-not (= ordered @feeds)
        (reset! feeds ordered)))))

(defn- pump-window!
  "Follow the window's width, so a call wall can divide it.

  Outside the `live?` guard: the width is wanted the frame a call *starts*, and
  a cell first written at that moment would lay the wall out against a zero.

  Written only when it changes, and only in whole points. A window being
  dragged produces a fractional width every frame, and a cell that took each
  one would re-render the wall for a third of a point of difference nobody can
  see."
  []
  (let [[w h] (vidya/screen-size)
        w (long w)
        h (long h)]
    (when-not (= w @window-width) (reset! window-width w))
    (when-not (= h @window-height) (reset! window-height h))))

(defn pump!
  "One frame's worth of the media plane. Cheap when no call is up.

  Runs on the loop thread — `vidya/frame-rgba!` may not be called from anywhere
  else, and neither may anything that touches a node."
  []
  (pump-window!)
  (when (live?)
    (pump-status!)
    (pump-frames!)
    (pump-feeds!)))

(defn init-logging!
  "Ask, once, whether calls can happen here.

  It used to do two things: turn on the Rust media plane's logging and, as
  a side effect of the call succeeding, discover that the plane existed.
  There is no Rust plane now and nothing to switch on — `frq.av.plane`
  raises where it fails and `poll-status!` carries the reason, both of
  which a jolt-level trace can already see.

  The name stays because `frq.app` calls it at startup and the answer it
  wants is unchanged: is there a media plane here at all."
  []
  (available?))

(defn install-pump!
  "Start pumping the media plane every frame. Returns a timer id, or nil where
  there is no media plane to pump.

  Sixteen milliseconds rather than a longer gap because this is where video
  arrives: polling slower than the window paints would show every other frame."
  []
  (when (available?)
    (vidya/every! 16 pump!)))

(defn tiles
  "Everyone with a picture in the current call, the self-view last.

  Reads the cell the pump writes, so a component calling this re-renders when
  someone turns their camera on."
  []
  @feeds)

;; What the wall cannot use: the window's own edges, the card the tiles sit in,
;; and the gaps between them. Measured against the chat screen's margins rather
;; than guessed — 12 a side outside the card, 8 a side within it.
(def ^:private wall-chrome 44)
(def ^:private tile-gap 8)

;; The size a tile wants to be. Columns are chosen to keep tiles near this
;; rather than to fit as many across as will physically go: four faces at a
;; hundred points each is worse than two rows of two at twice that, and a call
;; is people looking at each other, not a contact sheet.
(def ^:private want-tile 160)

;; A tile narrower than this is not a face, it is a thumbnail of one.
(def ^:private min-tile 96)

;; And an upper bound, so one person alone does not become a wall-sized
;; portrait. Generous rather than tight — what actually stops tiles growing is
;; the height budget below, and this is only here so there is an answer on a
;; screen tall enough that it never binds.
(def ^:private max-tile 720)

;; What a tile costs in height beyond its picture: the name under it, and the
;; gap to the row below.
(def ^:private tile-label 22)

;; The wall's share of the window height.
;;
;; A third was the first guess and it was wrong: on a 1920x1060 screen it held
;; one person to a 440-point tile with fourteen hundred points of empty width
;; beside them, which reads as video that will not scale — because in every way
;; the eye can tell, it does not. Half leaves the conversation legible under it
;; while letting a maximised window actually be worth maximising.
(def ^:private wall-share 0.5)

(defn- rows-for [n cols] (max 1 (quot (+ n (dec cols)) cols)))

(defn tile-width
  "How wide a tile is with `n` across and `rows` down, in a window of `width`
  by `height` points.

  Bounded by both axes, and the height is usually the one that binds. That is
  deliberate: a fixed ceiling meant a window dragged from half the screen to
  all of it changed the tiles by six points, because they were already against
  it. Deriving the ceiling from the wall's share of the height means a taller
  window really does make the faces bigger."
  [width height n rows]
  (let [n (max 1 n)
        rows (max 1 rows)
        across (max 0 (- (or width 0) wall-chrome (* tile-gap (dec n))))
        by-width (quot across n)
        ;; What the row height allows, once the name and the gap are paid for.
        down (- (quot (long (* (or height 0) wall-share)) rows) tile-gap tile-label)
        by-height (long (/ (max 0 down) 0.75))]
    (-> (min by-width by-height)
        (max min-tile)
        (min max-tile))))

(defn columns
  "How many tiles to put across, for the biggest tiles the window allows.

  Every arrangement from one row to one column is tried and the roomiest wins,
  because neither axis alone decides it: more columns buy height by spending
  width, and which is worth more depends on the shape of the window. Ties go to
  fewer columns, which is the arrangement with fewer rows."
  [width height n]
  (let [n (max 1 n)]
    (reduce (fn [best cols]
              (if (> (tile-width width height cols (rows-for n cols))
                     (tile-width width height best (rows-for n best)))
                cols
                best))
            1
            (range 2 (inc n)))))

(defn tile-rows
  "The tiles as `[width [[key ...] ...]]` — one width, and the rows to draw.

  One width for every tile, not one per row: a last row holding a single person
  would otherwise draw them at twice the size of everybody above, which reads
  as though something had gone wrong rather than as a layout."
  ([] (tile-rows @window-width @window-height (tiles)))
  ([width height keys]
   (let [n (count keys)
         cols (columns width height n)]
     [(tile-width width height cols (rows-for n cols))
      (mapv vec (partition-all cols keys))])))
