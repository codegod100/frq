(ns frq.av.audio
  "Opus over MoQ, and the jitter buffer that makes it listenable.

  Video can afford to be simple here: a frame arrives, it is decoded, it is
  painted, and if one is late the picture holds. Audio cannot. A gap in
  playback is audible as a click, arriving early is as bad as arriving late,
  and several peers have to be summed into ONE stream whose clock belongs to
  the sound card rather than to any of them. That is what this namespace is
  for, and it is why it is separate from `frq.av.plane` — mixing policy is a
  thing to be able to read on its own.

  THE MODEL. Fixed 20ms frames at 48kHz — 960 samples per channel, which is
  Opus's usual frame and what `frame-samples` is. Every peer decodes into a
  small ring; the mixer takes one frame from each peer's ring per tick and
  sums them. A peer whose ring is empty contributes Opus's own concealment
  rather than silence, because a dropped packet concealed sounds like a
  smudge where silence sounds like a click.

  THE THREE THINGS A JITTER BUFFER DECIDES, spelled out because the defaults
  are the whole design:

    * DEPTH. `target-depth` frames are accumulated before a peer is played
      at all. Too shallow and every network hiccup is a gap; too deep and
      the call gains latency nobody asked for. Two frames — 40ms — is the
      usual starting point for a conversation.
    * OVERFLOW. Past `max-depth` the OLDEST frame is dropped, not the
      newest. A listener wants the most recent audio; keeping the stale end
      of a backlog just delays everything behind it permanently.
    * UNDERFLOW. An empty ring conceals rather than stalls. Waiting for the
      late frame would stall every OTHER peer too, since they share the
      output clock.

  This is a deliberately plain buffer: fixed depth, no adaptation to
  measured jitter, no clock-drift resampling. Those are real and they are
  missing, and the note at `mix-into!` says what goes wrong without them."
  (:require [frq.codec.opus :as opus]
            [jolt.ffi :as ffi]))

(def ^:const sample-rate 48000)
(def ^:const frame-samples 960)          ; 20ms at 48kHz, per channel
(def ^:const target-depth 2)
(def ^:const max-depth 6)

;; --- OpusHead ----------------------------------------------------------------

(defn opus-head!
  "The 19-byte OpusHead an Opus track's catalog entry needs, into `p`.

  Little-endian, unlike everything else in this port — OpusHead is Ogg's
  header format and predates any of it. An audio track will not publish
  without one: video resolves its parameters in band and audio does not."
  [p channels]
  (let [magic [0x4f 0x70 0x75 0x73 0x48 0x65 0x61 0x64]   ; "OpusHead"
        pre-skip 3840]
    (dotimes [i 8] (ffi/write (+ p i) :uint8 (nth magic i)))
    (ffi/write (+ p 8) :uint8 1)                          ; version
    (ffi/write (+ p 9) :uint8 channels)
    (ffi/write (+ p 10) :uint8 (bit-and pre-skip 255))
    (ffi/write (+ p 11) :uint8 (bit-and (bit-shift-right pre-skip 8) 255))
    (dotimes [i 4]
      (ffi/write (+ p 12 i) :uint8
                 (bit-and (bit-shift-right sample-rate (* 8 i)) 255)))
    (ffi/write (+ p 16) :uint8 0)                         ; output gain lo
    (ffi/write (+ p 17) :uint8 0)                         ; output gain hi
    (ffi/write (+ p 18) :uint8 0)                         ; mapping family
    [p 19]))

;; --- a peer's ring -----------------------------------------------------------

(defn ring
  "A peer's decoded-audio ring: `max-depth` frames of foreign memory.

  Allocated once and reused. Decoding into fresh memory every 20ms would
  make the allocator part of the audio path, which is the one place it has
  no business being."
  [channels]
  {:decoder  (opus/decoder sample-rate channels)
   :channels channels
   :slots    (mapv (fn [_] (ffi/alloc (* 2 frame-samples channels)))
                   (range max-depth))
   :filled   (atom [])         ; indices holding audio, oldest first
   :free     (atom (vec (range max-depth)))
   :started? (atom false)})

(defn close-ring! [r]
  (opus/free-decoder! (:decoder r))
  (doseq [p (:slots r)] (ffi/free p))
  nil)

(defn push-packet!
  "Decode one Opus packet into the ring.

  Over `max-depth` the OLDEST frame goes, not this one: a listener wants the
  most recent audio, and keeping the stale end of a backlog delays
  everything behind it for the rest of the call."
  [r ptr len]
  (let [{:keys [decoder slots filled free channels]} r
        i (if-let [i (first @free)]
            (do (swap! free subvec 1) i)
            (let [oldest (first @filled)]
              (swap! filled subvec 1)
              oldest))
        n (opus/decode! decoder ptr len (nth slots i) frame-samples)]
    (swap! filled conj i)
    (when (>= (count @filled) target-depth) (reset! (:started? r) true))
    n))

(defn- take-frame!
  "The oldest frame in the ring, or nil while it is still filling."
  [r]
  (when @(:started? r)
    (when-let [i (first @(:filled r))]
      (swap! (:filled r) subvec 1)
      (swap! (:free r) conj i)
      (nth (:slots r) i))))

;; --- mixing ------------------------------------------------------------------

(defn mix-into!
  "Sum one frame from every ring into `out`; answers the peak written.

  Summed and CLAMPED, not averaged. Averaging would make every voice quieter
  as more people joined, which is the wrong behaviour in a meeting; clamping
  only bites when several people are loud at once, which is already
  unpleasant for other reasons.

  A ring with nothing in it conceals — `opus/decode!` with no packet is
  Opus's own loss concealment — rather than contributing silence, because a
  gap is a click and a concealed frame is a smudge.

  WHAT IS NOT HERE, and it will be audible eventually: no resampling for
  clock drift. The sound card's clock and the sender's are not the same, and
  over minutes one drifts against the other — the ring slowly fills or
  slowly empties, and the fix is to resample by a fraction of a percent
  rather than to keep dropping or concealing. That wants measurement this
  buffer does not yet take."
  [rings out channels]
  (let [n (* frame-samples channels)]
    (dotimes [i n] (ffi/write (+ out (* 2 i)) :int16 0))
    (doseq [r rings]
      (let [src (or (take-frame! r)
                    ;; Conceal: decode nothing, which Opus turns into a
                    ;; plausible continuation of what it last heard.
                    (let [slot (nth (:slots r) 0)]
                      (when @(:started? r)
                        (opus/decode! (:decoder r) nil 0 slot frame-samples)
                        slot)))]
        (when src
          (dotimes [i n]
            (let [a (ffi/read (+ out (* 2 i)) :int16)
                  b (ffi/read (+ src (* 2 i)) :int16)
                  v (+ a b)]
              (ffi/write (+ out (* 2 i)) :int16
                         (cond (> v 32767) 32767 (< v -32768) -32768 :else v)))))))
    (loop [i 0 peak 0]
      (if (= i n)
        peak
        (recur (inc i) (max peak (abs (ffi/read (+ out (* 2 i)) :int16))))))))
