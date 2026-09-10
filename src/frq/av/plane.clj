(ns frq.av.plane
  "The media plane, in jolt — what `libjoltmoq` was.

  `joltmoq_start` was one call that connected, published a camera, subscribed
  to every peer, decoded their video and mixed their audio, on its own Rust
  threads. This is the same job assembled from the pieces `frq.moq.*`,
  `frq.codec.*` and `frq.capture.*` now provide, and it deliberately keeps
  joltmoq's SHAPE so that `frq.av` becomes a change of call sites rather than
  a rewrite:

      start! stop! live?          joltmoq_start / _stop / _is_live
      poll-status!                joltmoq_poll_status + _status_text
      poll-frames!                joltmoq_frame_poll + _frame_rgba

  WHY IT IS PUMPED AND NOT THREADED. jolt has fibers, but a fiber is bound to
  its carrier for life and a blocking foreign call pins that carrier and
  strands everything queued behind it — and the two things this has to do
  most often, V4L2's DQBUF and ALSA's readi, are exactly that. So the plane is
  driven from `pump!`, which glimmer already calls from a timer for `frq.av`.
  It also keeps joltmoq's frame contract intact for free: at most one frame is
  decoded per poll, so the pointer handed out stays valid until the next one,
  which is precisely what `joltmoq_frame_rgba` promised.

  WHAT IS HERE. Video, for as many peers as announce themselves. Outbound is
  capture → H.264 → a MoQ media track. Inbound is DISCOVERED rather than
  configured: an announcement watch on the origin turns up each peer's
  broadcast, its catalog names the video track and says which container it is
  in, and from there it is subscribe → H.264 → RGBA per peer.

  Each peer keeps its OWN decoder, which is what makes several of them
  possible at all: a decoder's output buffer is overwritten by its next
  decode, so one shared between peers would hand out the same pixels for all
  of them. One decode per peer per pump, and the pointers stay good until
  that peer's next.

  What is still not here:

    * audio — Opus and ALSA are bound, but mixing several peers into one
      playback stream needs a jitter buffer and a resampler for clock drift,
      and a bad one is worse than none
    * Android, where neither V4L2 nor ALSA exists

  A SOURCE IS A FUNCTION, not a camera. `start!` takes `:source`, a thunk
  answering [pointer length] for one I420 frame or nil for \"nothing right
  now\". `frq.capture.v4l2` is one such thunk; a test pattern is another. That
  is what lets the plane be exercised on a machine with no camera, and it is
  also how the phone will pass a Camera2 buffer in later without this
  namespace learning about JNI."
  (:require [clojure.string :as str]
            [frq.av.audio :as audio]
            [frq.moq.media :as media]
            [frq.moq.uniffi :as uniffi]
            [frq.codec.h264 :as h264]
            [frq.codec.opus :as opus]
            [jolt.ffi :as ffi]))

;; --- state -------------------------------------------------------------------
;; One plane per process, as joltmoq had: its C API was all globals, and the
;; call surface above it assumes a single call at a time.

(declare stop!)

(defonce ^:private plane (atom nil))

(defn live? [] (some? @plane))

;; --- starting ----------------------------------------------------------------

(defn start!
  "Bring the plane up and answer true, or false with a reason recorded.

  `origin` is a MoqOriginProducer — from a session for a real call, or made
  locally for a test, which is the same object either way. `source` is the
  frame thunk described above.

  Everything that can fail does so HERE rather than at the first frame: the
  encoder validates its size, the decoder opens, and the subscribe settles,
  so a plane that comes up is one that can carry a picture."
  [{:keys [origin path source mic width height fps bitrate camera? muted?
           channels]
    :or   {path "/frq" width 640 height 480 fps 30 bitrate 800000
           camera? true muted? false channels 1}}]
  (stop!)
  (let [broadcast (media/create-broadcast! origin path)
        producer  (media/publish-media! broadcast "avc3")
        track     (media/producer-name producer)
        consumer  (media/broadcast-consumer broadcast)
        ;; The audio track rides the same publish_media as video — this
        ;; object has no publish_audio, that being moq-ffi's `audio`
        ;; feature. What it needs instead is an OpusHead up front: video
        ;; resolves its parameters in band and audio does not.
        [head-p head-n] (audio/opus-head! (ffi/alloc 19) channels)
        mic-producer (when mic
                       (media/publish-media-bytes! broadcast "opus"
                                                   head-p head-n))]
    (ffi/free head-p)
    (reset! plane
            {:broadcast broadcast
             :producer  producer
             :track     track
             :path      path
             ;; The announcement watch is the whole of peer discovery. An
             ;; empty prefix takes everything on the origin, because in a
             ;; call every participant is a broadcast and none of their
             ;; paths are known in advance.
             :announced (media/announced! (media/origin-consumer origin) "")
             :announce  nil
             :peers     {}
             :encoder   (h264/encoder {:width width :height height
                                       :fps fps :bitrate bitrate})
             :mic-producer mic-producer
             :mic-encoder  (when mic (opus/encoder audio/sample-rate channels :voip))
             :mic          mic
             :muted?       muted?
             :channels     channels
             :mix          (ffi/alloc (* 2 audio/frame-samples channels))
             :mixed        nil
             :source    source
             :size      [width height]
             :camera?   camera?
             :frames    []
             :status    (atom [])
             :pts       (atom 0)
             :fps       fps})
    true))

(defn stop!
  "Take the plane down and release everything it holds."
  []
  (when-let [p @plane]
    (try (h264/close! (:encoder p)) (catch Exception _ nil))
    (doseq [[_ peer] (:peers p)]
      (try (h264/close-decoder! (:decoder peer)) (catch Exception _ nil))
      (when-let [r (:ring peer)] (try (audio/close-ring! r) (catch Exception _ nil))))
    (when-let [e (:mic-encoder p)] (try (opus/free-encoder! e) (catch Exception _ nil)))
    (when-let [m (:mix p)] (try (ffi/free m) (catch Exception _ nil)))
    (reset! plane nil))
  nil)

;; --- controls ----------------------------------------------------------------

(defn set-camera!
  "Publishing on or off. Off stops the encoder being fed; it does not tear the
  track down, because a subscriber that saw the track vanish and reappear
  would have to rediscover it."
  [on?]
  (swap! plane #(when % (assoc % :camera? (boolean on?))))
  nil)

(defn set-muted!
  "Stop feeding the encoder. The track stays published — a peer who saw it
  vanish would have to rediscover it to hear you unmute."
  [muted?]
  (swap! plane #(when % (assoc % :muted? (boolean muted?))))
  nil)

(defn force-keyframe!
  "Make the next published frame an IDR.

  What a subscriber joining mid-call needs: the second frame out of an
  encoder is a P-frame, and a decoder handed one first has no SPS or PPS to
  decode against and says so."
  []
  (when-let [p @plane] (h264/force-keyframe! (:encoder p)))
  nil)

;; --- the outbound half -------------------------------------------------------

(defn- pump-out!
  "Take one frame from the source, encode it, publish it."
  [{:keys [source encoder producer camera? pts fps]}]
  (when (and camera? source)
    (when-let [[px _len] (source)]
      (let [us (swap! pts + (quot 1000000 (max 1 fps)))]
        (h264/encode!
          encoder px us
          (fn [p len _key?]
            ;; A skipped frame is a decision, not a failure — openh264
            ;; answers zero length and there is simply nothing to send.
            (when (pos? len)
              (media/write-video-frame! producer p len us))))))))

;; --- the inbound half -------------------------------------------------------

(defn- settle
  "Answer a settled future's value, or nil while it has not settled.

  Never blocks: an unsettled future is polled again and nil comes back, which
  is what lets this be called from the loop thread as often as a timer fires."
  [fut lift]
  (when (and fut (uniffi/settled? fut))
    (if lift (uniffi/complete! fut lift) (uniffi/complete! fut))))

(defn- normalise-path
  "An origin announces `us` for a broadcast created as `/us`.

  The leading slash is ours, not the origin's: `create-broadcast!` takes the
  path we hand it and announcements come back relative to the origin root.
  Comparing the two verbatim is how the self-view stops being recognised as
  ours — which does not fail loudly, it just puts your own face in the grid
  under a peer's name."
  [path]
  (when path (str/replace path #"^/+" "")))

(defn- pump-announce!
  "Advance the announcement watch; add a peer for anything new.

  Our own broadcast is announced back to us like anyone else's, and it is
  taken as the self-view rather than filtered out — `frq.av` already has a
  key for that and a self-view is a picture the person expects to see."
  [p]
  (let [p (if (:announce p) p (assoc p :announce (media/next-announcement! (:announced p))))]
    (if-let [ann (settle (:announce p) media/lift-announcement)]
      (let [path (media/announcement-path ann)
            p    (assoc p :announce nil)]
        (if (contains? (:peers p) path)
          p
          (assoc-in p [:peers path]
                    {:broadcast (media/announcement-broadcast ann)
                     :catalog   nil
                     :catalog-pending nil
                     :subscribe nil
                     :media     nil
                     :pending   nil
                     :decoder   (h264/decoder)
                     :self?     (= (normalise-path path)
                                   (normalise-path (:path p)))})))
      p)))

(defn- pump-peer-audio!
  "Advance one peer's audio: catalog says the track, then subscribe, then
  decode into that peer's ring.

  Separate from the video walk because the two are independent — a peer with
  a camera off still has a voice, and blocking one on the other is how a
  muted-video participant goes silent too."
  [peer channels]
  (cond
    (nil? (get-in peer [:catalog :audio-track])) peer

    (nil? (:audio-media peer))
    (let [peer (if (:audio-subscribe peer)
                 peer
                 (assoc peer :audio-subscribe
                        (media/subscribe-media! (:broadcast peer)
                                                (get-in peer [:catalog :audio-track])
                                                (get-in peer [:catalog :audio-container]))))]
      (if-let [mc (settle (:audio-subscribe peer) nil)]
        (assoc peer :audio-media mc :audio-subscribe nil
                    :ring (audio/ring channels))
        peer))

    :else
    (let [peer (if (:audio-pending peer)
                 peer
                 (assoc peer :audio-pending (media/next-frame! (:audio-media peer))))
          got  (settle (:audio-pending peer)
                       #(media/lift-media-frame
                          %
                          (fn [ptr len]
                            (when (pos? len)
                              (audio/push-packet! (:ring peer) ptr len)
                              true))))]
      (if got (assoc peer :audio-pending nil) peer))))

(defn- pump-peer!
  "Walk one peer from announced to a decoded picture.

  Four states, advanced at most one step per pump so that no peer can hold
  the loop thread: subscribe the catalog, read it for a video track name and
  its container, subscribe that track, then decode a frame from it."
  [peer]
  (cond
    ;; 1. The catalog: what tracks this peer has, and in which container.
    (nil? (:catalog peer))
    (let [peer (if (:catalog-pending peer)
                 peer
                 (assoc peer :catalog-pending
                        {:sub (media/subscribe-catalog! (:broadcast peer))}))
          sub  (:catalog-pending peer)]
      (cond
        (:consumer sub)
        (let [cp (or (:next sub) (media/next-catalog! (:consumer sub)))]
          (if-let [cat (settle cp media/lift-catalog)]
            (let [[track video]  (first (:video cat))
                  [atrack aud]   (first (:audio cat))]
              ;; EITHER is enough. Requiring video here is how an audio-only
              ;; peer waits for ever: with no picture coming the catalog is
              ;; never accepted, so the audio track named in the same
              ;; catalog is never read either, and someone with their camera
              ;; off goes silent as well as dark.
              (if (or track atrack)
                (assoc peer :catalog {:track track
                                      :container (:container video)
                                      :audio-track atrack
                                      :audio-container (:container aud)}
                            :catalog-pending nil)
                ;; Nothing published yet. Ask again.
                (assoc peer :catalog-pending {:consumer (:consumer sub) :next nil})))
            (assoc peer :catalog-pending {:consumer (:consumer sub) :next cp})))

        :else
        (if-let [cc (settle (:sub sub) nil)]
          (assoc peer :catalog-pending {:consumer cc :next nil})
          peer)))

    ;; No picture from this peer — audio only, or camera off. Not a state
    ;; to advance out of; their audio walks on its own.
    (nil? (get-in peer [:catalog :track])) peer

    ;; 2. Subscribe to the track the catalog named.
    (nil? (:media peer))
    (let [peer (if (:subscribe peer)
                 peer
                 (assoc peer :subscribe
                        (media/subscribe-media! (:broadcast peer)
                                                (get-in peer [:catalog :track])
                                                (get-in peer [:catalog :container]))))]
      (if-let [mc (settle (:subscribe peer) nil)]
        (assoc peer :media mc :subscribe nil)
        peer))

    ;; 3. A frame.
    :else
    (let [peer (if (:pending peer) peer (assoc peer :pending (media/next-frame! (:media peer))))
          ;; The decode happens INSIDE the lift, while the RustBuffer the
          ;; payload points into is still alive. Lifting the span out and
          ;; decoding afterwards reads a buffer that has already been freed,
          ;; and what comes back from that is not a fault but plausible
          ;; rubbish.
          ;;
          ;; The RGBA pointer it answers belongs to this peer's DECODER, not
          ;; to the RustBuffer, so it outlives the lift and is good until
          ;; this peer decodes again.
          decoded (settle (:pending peer)
                          #(media/lift-media-frame
                             %
                             (fn [ptr len]
                               (when (pos? len)
                                 (h264/decode!
                                   (:decoder peer) ptr len
                                   (fn [rgba w h]
                                     (when-not (or (ffi/null? rgba) (zero? w))
                                       {:w w :h h :rgba rgba})))))))]
      (if decoded
        (assoc peer :pending nil :frame (:payload decoded))
        (assoc peer :frame nil)))))

(defn- pump-mic!
  "One 20ms frame from the microphone, encoded and published."
  [{:keys [mic mic-encoder mic-producer muted? pts channels]}]
  (when (and mic mic-encoder mic-producer (not muted?))
    (when-let [[pcm _] (mic)]
      (ffi/with-arena [a]
        (let [out (ffi/alloc a 4000)
              n   (opus/encode! mic-encoder pcm audio/frame-samples out 4000)]
          ;; DTX is the encoder saying this frame is silence and need not be
          ;; sent. Sending it anyway would be bytes for nothing.
          (when-not (opus/dtx? n)
            (media/write-video-frame! mic-producer out n @pts)))))))

(defn- pump-in!
  "Discover peers, then advance every one of them."
  [p]
  (let [p     (pump-announce! p)
        peers (reduce-kv (fn [m path peer]
                           (assoc m path (-> peer
                                             pump-peer!
                                             (pump-peer-audio! (:channels p)))))
                         {} (:peers p))]
    (assoc p
           :peers peers
           :frames (into []
                         (keep (fn [[path peer]]
                                 (when-let [f (:frame peer)]
                                   (assoc f :key (if (:self? peer) "__local__" path)))))
                         peers))))

;; --- the pump ----------------------------------------------------------------

(defn pump!
  "Drive both halves once. Called from the same timer as `frq.av/pump!`."
  []
  (when-let [p @plane]
    (pump-out! p)
    (pump-mic! p)
    (let [p' (pump-in! p)
          ;; Mix everyone EXCEPT ourselves: hearing your own voice back is
          ;; the thing headphones exist to prevent.
          rings (keep (fn [[_ peer]] (when-not (:self? peer) (:ring peer)))
                      (:peers p'))
          peak  (when (seq rings)
                  (audio/mix-into! rings (:mix p') (:channels p')))]
      (reset! plane (assoc p' :mixed (when peak
                                       {:ptr (:mix p')
                                        :samples audio/frame-samples
                                        :peak peak})))))
  nil)

(defn poll-frames!
  "Every frame decoded by the last `pump!`, one per peer at most.

  Each is {:key :w :h :rgba} with `:key` the peer's broadcast path, or
  \"__local__\" for our own. `:rgba` is BORROWED — it is that peer's decoder
  buffer and that peer's next decode overwrites it — so hand each to
  `vidya/frame-rgba!` and let it go. Copying is the one copy this whole path
  exists to avoid.

  Several frames at once is safe precisely because the decoders are
  per-peer: one shared decoder would make every pointer here alias the last
  picture decoded."
  []
  (:frames @plane))

(defn poll-audio!
  "The mixed 20ms frame from the last `pump!`, or nil.

  {:ptr :samples :peak} — interleaved int16 ready for `alsa/write!`, and
  BORROWED like everything else here: the next pump mixes over it."
  []
  (:mixed @plane))

(defn peers
  "The broadcast paths currently known, self included."
  []
  (some-> @plane :peers keys vec))

(defn poll-status!
  "Drain what the plane has learned, as [code text] pairs, oldest first."
  []
  (when-let [p @plane]
    (let [q (:status p)
          v @q]
      (reset! q [])
      v)))
