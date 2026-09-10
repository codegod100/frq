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
      poll-frame!                 joltmoq_frame_poll + _frame_rgba

  WHY IT IS PUMPED AND NOT THREADED. jolt has fibers, but a fiber is bound to
  its carrier for life and a blocking foreign call pins that carrier and
  strands everything queued behind it — and the two things this has to do
  most often, V4L2's DQBUF and ALSA's readi, are exactly that. So the plane is
  driven from `pump!`, which glimmer already calls from a timer for `frq.av`.
  It also keeps joltmoq's frame contract intact for free: at most one frame is
  decoded per poll, so the pointer handed out stays valid until the next one,
  which is precisely what `joltmoq_frame_rgba` promised.

  WHAT IS HERE. One peer, video only. Outbound is capture → H.264 → a MoQ
  media track; inbound is that track → H.264 → RGBA. That is enough to carry
  a picture end to end and it is deliberately the smallest thing that can be,
  because the parts that are NOT here are the ones worth doing carefully:

    * more than one peer, and the announce/catalog handling that finds them
    * audio at all — Opus and ALSA are bound, but mixing several peers into
      one playback stream needs a jitter buffer and a resampler for clock
      drift, and a bad one is worse than none
    * Android, where neither V4L2 nor ALSA exists

  A SOURCE IS A FUNCTION, not a camera. `start!` takes `:source`, a thunk
  answering [pointer length] for one I420 frame or nil for \"nothing right
  now\". `frq.capture.v4l2` is one such thunk; a test pattern is another. That
  is what lets the plane be exercised on a machine with no camera, and it is
  also how the phone will pass a Camera2 buffer in later without this
  namespace learning about JNI."
  (:require [frq.moq.media :as media]
            [frq.moq.uniffi :as uniffi]
            [frq.codec.h264 :as h264]
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
  [{:keys [origin path source width height fps bitrate camera?]
    :or   {path "/frq" width 640 height 480 fps 30 bitrate 800000 camera? true}}]
  (stop!)
  (let [broadcast (media/create-broadcast! origin path)
        producer  (media/publish-media! broadcast "avc3")
        track     (media/producer-name producer)
        consumer  (media/broadcast-consumer broadcast)]
    (reset! plane
            {:broadcast broadcast
             :producer  producer
             :track     track
             :consumer  consumer
             :subscribe (media/subscribe-media! consumer track media/video-container)
             :media     nil
             :pending   nil
             :encoder   (h264/encoder {:width width :height height
                                       :fps fps :bitrate bitrate})
             :decoder   (h264/decoder)
             :source    source
             :size      [width height]
             :camera?   camera?
             :frame     nil
             :status    (atom [])
             :pts       (atom 0)
             :fps       fps})
    true))

(defn stop!
  "Take the plane down and release everything it holds."
  []
  (when-let [p @plane]
    (try (h264/close! (:encoder p)) (catch Exception _ nil))
    (try (h264/close-decoder! (:decoder p)) (catch Exception _ nil))
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

;; --- the inbound half --------------------------------------------------------

(defn- settle
  "Answer a settled future's value, or nil while it has not settled.

  Never blocks: an unsettled future is polled again and nil comes back, which
  is what lets this be called from the loop thread as often as a timer fires."
  [fut lift]
  (when (and fut (uniffi/settled? fut))
    (if lift (uniffi/complete! fut lift) (uniffi/complete! fut))))

(defn- pump-in!
  "Advance the subscribe, then take at most ONE frame and decode it.

  One, not all of them: the decoder answers a pointer into its own buffer and
  the next decode overwrites it, so draining the queue here would hand out
  three pointers to the same pixels. joltmoq had the same rule and stated it
  the same way."
  [p]
  (let [p (if (and (:subscribe p) (nil? (:media p)))
            (if-let [mc (settle (:subscribe p) nil)]
              (assoc p :media mc :subscribe nil)
              p)
            p)]
    (if-not (:media p)
      p
      (let [p (if (:pending p) p (assoc p :pending (media/next-frame! (:media p))))
            ;; The decode happens INSIDE the lift, while the RustBuffer the
            ;; payload points into is still alive. Lifting a span out and
            ;; decoding afterwards reads a buffer that has already been
            ;; freed — and what comes back from that is not a fault but
            ;; plausible rubbish, which is the worst kind.
            ;;
            ;; The RGBA pointer it answers is the DECODER's buffer, not the
            ;; RustBuffer's, so it outlives this and is good until the next
            ;; decode. That is the borrow `poll-frame!` hands on.
            decoded (settle (:pending p)
                            #(media/lift-media-frame
                               %
                               (fn [ptr len]
                                 (when (pos? len)
                                   (h264/decode!
                                     (:decoder p) ptr len
                                     (fn [rgba w h]
                                       (when-not (or (ffi/null? rgba) (zero? w))
                                         {:key "peer" :w w :h h :rgba rgba})))))))]
        (if decoded
          (assoc p :pending nil :frame (:payload decoded))
          (assoc p :frame nil))))))

;; --- the pump ----------------------------------------------------------------

(defn pump!
  "Drive both halves once. Called from the same timer as `frq.av/pump!`."
  []
  (when-let [p @plane]
    (pump-out! p)
    (reset! plane (pump-in! p)))
  nil)

(defn poll-frame!
  "The frame decoded by the last `pump!`, or nil.

  {:key :w :h :rgba}, where `:rgba` is BORROWED — it is the decoder's own
  buffer and the next `pump!` overwrites it. Hand it to `vidya/frame-rgba!`
  and let it go; copying it is the one copy this whole path exists to avoid."
  []
  (:frame @plane))

(defn poll-status!
  "Drain what the plane has learned, as [code text] pairs, oldest first."
  []
  (when-let [p @plane]
    (let [q (:status p)
          v @q]
      (reset! q [])
      v)))
