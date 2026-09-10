(ns frq.moq.smoke
  "The smallest round trip that proves the generated bindings are real.

  Nothing in `frq.moq.*` has crossed the ABI until something does, and the
  failure modes here are not the kind that announce themselves: a RustBuffer
  whose fields are the wrong width reads as plausible garbage, and a handle
  freed twice corrupts an allocator some minutes later rather than at the call.
  So this checks, in order, the three things everything else assumes —

    1. the contract version, which is the object saying it is the one the
       bindings were generated from;
    2. a handle's whole life — construct a MoqClient, then free it — which is
       the RustCallStatus out-parameter working in both directions;
    3. a string out and back, which is the RustBuffer layout and the
       alloc/free ownership rule.

    4. a connect, which is the only one of these that involves a tokio worker
       and therefore the only one that exercises the continuation callback —
       the piece with the most ways to be quietly wrong, since it runs on a
       thread jolt never started.

  The connect is aimed at a port nothing is listening on. That is on purpose:
  what is under test is the future protocol and the error path, and both of
  those are the same whether the far side refuses or is simply not there —
  where a real relay would make this test depend on somebody else's uptime.

  It takes THIRTY SECONDS, and that is not this code being slow. QUIC runs
  over UDP, so a closed port produces no connection-refused to notice: there
  is only the handshake timeout, which moq-native sets to 30s. The deadline
  below has to sit above it, and a test that gave up at 15s reported a
  continuation that had never fired when what had happened was that nothing
  had gone wrong yet.

      just repl -m frq.moq.smoke"
  (:require [clojure.string :as str]
            [frq.moq.uniffi :as uniffi]
            [frq.moq.raw :as raw]
            [frq.moq.client :as client]
            [frq.moq.media :as media]
            [frq.codec.opus :as opus]
            [frq.codec.h264 :as h264]
            [frq.capture.v4l2 :as v4l2]
            [frq.capture.alsa :as alsa]
            [frq.capture.source :as source]
            [frq.av.plane :as plane]
            [frq.av.audio :as audio]
            [jolt.ffi :as ffi]))

(defn- check-contract []
  (let [v (uniffi/check-abi!)]
    (println "  contract version:" v "(expected" uniffi/expected-contract ")")
    true))

(defn- check-handle
  "Construct and free a MoqClient.

  `moqclient_new` is the one constructor that takes nothing but a status, so
  it isolates the status protocol from any argument lowering. The free is not
  a courtesy: it is the other half of the handle contract, and a binding that
  cannot free is a binding that leaks a QUIC endpoint per call."
  []
  (let [h (uniffi/with-out-status #(raw/constructor-moqclient-new %))]
    (println "  moqclient_new ->" h)
    (when (zero? h)
      (throw (ex-info "moqclient_new answered a null handle" {})))
    (uniffi/with-out-status #(raw/free-moqclient h %))
    (println "  free_moqclient ok")
    true))

(defn- check-string
  "Send a string into a RustBuffer and read it back out.

  The value is chosen to catch the two mistakes a length-counted buffer
  invites: multi-byte UTF-8 (a length in characters rather than bytes reads
  short) and a trailing character (a NUL-terminated read runs past the end)."
  []
  (let [s "moq://relay.example/ünïcode/✓"]
    (ffi/with-arena [a]
      (let [buf (ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
        (uniffi/lower-string buf s)
        (let [len (ffi/read-field buf uniffi/rust-buffer [:len])
              got (uniffi/lift-string buf)]
          (println "  lowered" (count s) "chars ->" len "bytes in the buffer")
          (println "  lifted  " (pr-str got))
          (when-not (= s got)
            (throw (ex-info "string did not round trip"
                            {:sent s :got got})))
          true)))))

(defn- check-connect
  "Connect to a closed port and watch the future fail.

  Everything interesting is in the loop: `poll-connect!` answers nil while the
  far side has not settled, and each nil has issued another poll. That the
  answer eventually changes at all is the continuation callback firing from a
  tokio thread and this thread seeing it — which is the whole reason for the
  atom in `frq.moq.uniffi/continuation`.

  A raise is the PASS here. What would be a failure is a hang (the
  continuation never fires) or a success (a connect to a closed port cannot
  succeed, so a session handle would mean the future protocol handed us
  something that is not a session)."
  []
  (let [c (client/new-client)]
    (try
      (let [fut (client/connect! c "https://127.0.0.1:1/smoke")
            deadline (+ (System/currentTimeMillis) 45000)]
        (println "  connect started, polling")
        (loop [polls 0]
          (cond
            (> (System/currentTimeMillis) deadline)
            (throw (ex-info "connect future never settled — the continuation did not fire"
                            {:polls polls}))

            :else
            (let [r (try
                      {:ok (client/poll-connect! fut)}
                      (catch clojure.lang.ExceptionInfo e {:err e}))]
              (cond
                (:err r)
                (let [d (ex-data (:err r))]
                  (println "  settled after" polls "polls")
                  (println "  variant:" (:variant d))
                  (println "  message:" (pr-str (:message d)))
                  (when-not (:variant d)
                    (throw (ex-info "error carried no MoqError variant — the buffer did not decode"
                                    {:data d})))
                  true)

                (:ok r)
                (throw (ex-info "connect to a closed port answered a session"
                                {:handle (:ok r)}))

                :else
                (do (Thread/sleep 20) (recur (inc polls))))))))
      (finally
        (client/free-client! c)
        (println "  free_moqclient ok")))))

(defn- settle!
  "Poll `fut` until it settles, or give up. Returns what it settled to.

  The polling is the point: every nil here has issued another poll, and this
  is what a caller on the loop thread would be doing from a timer instead of
  from a loop like this one."
  ([fut what ms] (settle! fut what ms nil))
  ([fut what ms lift]
  ;; ms 0 means one look and no waiting — for a caller with its own loop.
  (let [deadline (+ (System/currentTimeMillis) ms)]
    (loop []
      (cond
        (uniffi/settled? fut) (if lift
                                (uniffi/complete! fut lift)
                                (uniffi/complete! fut))
        (zero? ms) nil
        (> (System/currentTimeMillis) deadline)
        (throw (ex-info (str what ": future never settled") {:after-ms ms}))
        :else (do (Thread/sleep 10) (recur)))))))

(defn- check-media
  "Put a payload into a broadcast and take the same payload out of it.

  Entirely in-process: an origin producer is a plain constructor, so the
  broadcast a subscriber consumes here is the one the producer writes to, with
  no QUIC in between. That exercises argument lowering (a top-level string, an
  enum, an optional, a record), both subscribe paths, and the frame decode —
  everything except the wire itself.

  TWO tracks, because they prove different things. `subscribe_media` is the
  one frq.av will use, and it is checked as far as it can be checked here: a
  media track declares a codec, and avc3 means the container really does try
  to read Annex B out of whatever arrives, so a frame carrying the word hello
  is never going to come back out of it. The opaque track beside it parses
  nothing, which is what lets the payload round trip be an actual assertion
  rather than a hope."
  []
  (let [origin    (media/new-origin)
        broadcast (media/create-broadcast! origin "/smoke")
        producer  (media/publish-media! broadcast "avc3")
        track     (media/producer-name producer)
        consumer  (media/broadcast-consumer broadcast)]
    (println "  origin, broadcast, media track:" (pr-str track))

    ;; The media path: subscribing is the assertion.
    (let [mc (settle! (media/subscribe-media! consumer track :loc) "subscribe_media" 10000)]
      (println "  subscribe_media ->" mc)
      (when (zero? mc)
        (throw (ex-info "subscribe_media answered a null handle" {}))))

    ;; The opaque path: the payload is the assertion.
    (let [tp (media/publish-track! broadcast "data")
          tc (settle! (media/subscribe-track! consumer "data") "subscribe_track" 10000)]
      (println "  subscribe_track ->" tc)
      (media/write-track-frame! tp "hello-from-a-frame" 1234567)
      (println "  wrote a frame")
      (let [frame (settle! (media/read-frame! tc) "read_frame" 10000
                           media/lift-plain-frame)]
        (println "  got frame:" (pr-str frame))
        (when-not frame
          (throw (ex-info "track ended instead of delivering a frame" {})))
        (when-not (= "hello-from-a-frame" (:payload frame))
          (throw (ex-info "payload did not survive" {:frame frame})))
        (when-not (= 1234567 (:timestamp-us frame))
          (throw (ex-info "timestamp did not survive" {:frame frame})))
        true))))

(defn- triangle-pcm
  "20ms of a triangle wave at 48kHz mono, as int16 in FOREIGN memory.

  A triangle rather than a sine because it needs no transcendental and no
  Math namespace, and rather than silence because silence is the one input
  Opus is entitled to throw away: DTX would answer two bytes and the round
  trip would prove nothing.

  Answers [pointer samples-per-channel]."
  [a]
  (let [n 960                            ; 48000 * 0.020
        p (ffi/alloc a (* 2 n))]
    (dotimes [i n]
      ;; A 100-sample period ramp, +/- 8000 — loud enough that the decoder
      ;; cannot answer silence and have it look like success.
      (let [phase (mod i 100)
            v     (if (< phase 50) (- (* phase 320) 8000) (- 8000 (* (- phase 50) 320)))]
        (ffi/write (+ p (* 2 i)) :int16 v)))
    [p n]))

(defn- check-opus
  "Encode a frame with libopus and decode it back.

  This is the first piece of the port that is a C library rather than
  somebody's binding to one, and the assertions are chosen to fail if it is
  only pretending to work. The encoded frame must be more than DTX's two
  bytes; the decode must answer exactly the frame size it was given; and the
  decoded audio must carry real amplitude, because a decoder that returned
  the right COUNT of zeroes would otherwise pass."
  []
  (ffi/with-arena [a]
    (let [enc (opus/encoder 48000 1 :voip)
          dec (opus/decoder 48000 1)]
      (try
        (opus/set-bitrate! enc 24000)
        (let [[pcm n]  (triangle-pcm a)
              cap      4000
              out      (ffi/alloc a cap)
              written  (opus/encode! enc pcm n out cap)]
          (println "  encoded" n "samples ->" written "bytes")
          (when (opus/dtx? written)
            (throw (ex-info "encoder answered DTX for a loud frame"
                            {:written written})))
          (let [back    (ffi/alloc a (* 2 n))
                decoded (opus/decode! dec out written back n)
                peak    (reduce (fn [m i]
                                  (max m (abs (ffi/read (+ back (* 2 i)) :int16))))
                                0 (range decoded))]
            (println "  decoded" decoded "samples, peak" peak)
            (when-not (= n decoded)
              (throw (ex-info "decoder answered a different frame size"
                              {:sent n :got decoded})))
            (when (< peak 1000)
              (throw (ex-info "decoded audio is silent — a lossy codec is not this lossy"
                              {:peak peak})))
            true))
        (finally
          (opus/free-encoder! enc)
          (opus/free-decoder! dec))))))

(defn- check-h264
  "Encode an I420 frame to H.264 through the openh264 shim.

  The assertion is the Annex B start code. A frame that came back with a
  plausible length and the wrong bytes would be a vtable walked incorrectly —
  the shim reading the wrong slot, or flattening the layers wrong — and a
  length check alone would not catch it. 00 00 00 01 at the front, and an
  IDR for the first frame, is openh264 having actually encoded something.

  The picture is flat gray, which compresses to almost nothing; what is under
  test is the calling convention, not the encoder."
  []
  (ffi/with-arena [a]
    (let [w 64 h 64
          n   (h264/i420-size w h)
          px  (ffi/alloc a n)
          enc (h264/encoder {:width w :height h :fps 30 :bitrate 200000})]
      (dotimes [i n] (ffi/write (+ px i) :uint8 0x80))
      (try
        (let [got (h264/encode! enc px 0
                                (fn [p len key?]
                                  ;; The span is the encoder's buffer and dies
                                  ;; at the next encode: read what is needed
                                  ;; here and let it go.
                                  {:len len
                                   :keyframe key?
                                   :first-4 (mapv #(ffi/read (+ p %) :uint8)
                                                  (range (min 4 len)))}))]
          (println "  encoded" n "bytes of I420 ->" (:len got)
                   "bytes, keyframe" (:keyframe got)
                   "starts" (pr-str (:first-4 got)))
          (when (zero? (:len got))
            (throw (ex-info "encoder skipped the first frame" {})))
          (when-not (= [0 0 0 1] (:first-4 got))
            (throw (ex-info "not Annex B — no start code" {:first-4 (:first-4 got)})))
          (when-not (:keyframe got)
            (throw (ex-info "first frame is not an IDR" {})))

          ;; And back again. A decode that answered the right SIZE full of
          ;; the wrong pixels would pass a length check, so the assertion is
          ;; the picture: flat gray in, flat gray out, opaque.
          (let [dec (h264/decoder)]
            (try
              ;; The frame above was the IDR; this one would be a P-frame
              ;; referencing it, and a decoder handed that first answers
              ;; dsNoParamSets (16) — no SPS or PPS to decode against. A
              ;; subscriber joining mid-call is in exactly that position,
              ;; which is what force-keyframe! is for.
              (h264/force-keyframe! enc)
              (h264/encode! enc px 33333
                (fn [p len _]
                  (h264/decode! dec p len
                    (fn [rgba dw dh]
                      (println "  decoded ->" dw "x" dh "RGBA")
                      (when (or (zero? dw) (ffi/null? rgba))
                        (throw (ex-info "decoder produced no picture" {})))
                      (when-not (and (= w dw) (= h dh))
                        (throw (ex-info "decoded size does not match"
                                        {:want [w h] :got [dw dh]})))
                      (let [px0 (mapv #(ffi/read (+ rgba %) :uint8) (range 4))
                            mid (* 4 (+ (* (quot dh 2) dw) (quot dw 2)))
                            pxm (mapv #(ffi/read (+ rgba mid %) :uint8) (range 4))]
                        (println "  first pixel" (pr-str px0) "centre" (pr-str pxm))
                        (when-not (= 255 (nth px0 3))
                          (throw (ex-info "alpha is not opaque" {:pixel px0})))
                        ;; 0x80 luma with neutral chroma is mid gray; the
                        ;; BT.601 maths lands near 125, not exactly 128.
                        (doseq [c (take 3 pxm)]
                          (when-not (< 100 c 150)
                            (throw (ex-info "centre pixel is not gray"
                                            {:pixel pxm})))))
                      true))))
              (finally (h264/close-decoder! dec))))
          true)
        (finally (h264/close! enc))))))

(defn- check-v4l2-layouts
  "Check every V4L2 struct against what a C compiler says.

  There is no camera in this container, so the capture path itself cannot be
  exercised here. What CAN be checked is the part most likely to be wrong and
  least likely to announce it: every VIDIOC_ request number encodes the size
  of the struct it carries, so a layout one byte off does not misread a field
  — it produces a request the kernel has never heard of, and the driver
  answers ENOTTY for an ioctl that plainly exists.

  The numbers on the right came from a C program compiled against this
  kernel's own headers (scratch/v4l2probe.c). They are the ground truth this
  namespace is transcribed from, so checking against them catches a typo
  rather than a misunderstanding — the misunderstanding needs a device."
  []
  (let [checks [["v4l2_capability size"      (ffi/layout-size v4l2/capability) 104]
                ["  capabilities@"           (ffi/field-offset v4l2/capability [:capabilities]) 84]
                ["  device-caps@"            (ffi/field-offset v4l2/capability [:device-caps]) 88]
                ["v4l2_format size"          (ffi/layout-size v4l2/format-pix) 208]
                ["  width@"                  (ffi/field-offset v4l2/format-pix [:width]) 8]
                ["  height@"                 (ffi/field-offset v4l2/format-pix [:height]) 12]
                ["  pixelformat@"            (ffi/field-offset v4l2/format-pix [:pixelformat]) 16]
                ["  sizeimage@"              (ffi/field-offset v4l2/format-pix [:sizeimage]) 28]
                ["v4l2_requestbuffers size"  (ffi/layout-size v4l2/requestbuffers) 20]
                ["v4l2_buffer size"          (ffi/layout-size v4l2/buffer) 88]
                ["  bytesused@"              (ffi/field-offset v4l2/buffer [:bytesused]) 8]
                ["  timestamp@"              (ffi/field-offset v4l2/buffer [:tv-sec]) 24]
                ["  memory@"                 (ffi/field-offset v4l2/buffer [:memory]) 60]
                ["  m.offset@"               (ffi/field-offset v4l2/buffer [:offset]) 64]
                ["  length@"                 (ffi/field-offset v4l2/buffer [:length]) 72]]
        bad   (remove (fn [[_ got want]] (= got want)) checks)]
    (doseq [[what got want] checks]
      (println (str "  " what " " got (when-not (= got want) (str " WANT " want)))))
    (when (seq bad)
      (throw (ex-info "V4L2 layouts do not match the kernel headers"
                      {:mismatched (mapv (fn [[w g want]] {:what w :got g :want want}) bad)})))
    (println "  (no camera here — the capture path itself is unexercised)")
    true))

(defn- check-alsa
  "Open a PCM and push frames through it.

  The device is ALSA's `null` PCM, which swallows everything and is always
  present — no hardware, no permissions, and nothing that depends on what
  this container happens to have plugged in. What that proves is the binding:
  the library loads, the handle out-parameter comes back, set_params accepts
  the format, and writei answers in FRAMES. What it cannot prove is that a
  real card behaves, which needs a real card.

  The frame count is the assertion. 960 frames of mono S16 is 1920 bytes, and
  a writei that answered 1920 would be this code having confused the two —
  the mistake the namespace docstring warns about, and the one that looks
  like a slow device rather than a bug."
  []
  (ffi/with-arena [a]
    (let [frames 960
          buf    (ffi/alloc a (* 2 frames))
          pcm    (alsa/open-pcm "null" :playback {:rate 48000 :channels 1})]
      (try
        (dotimes [i frames] (ffi/write (+ buf (* 2 i)) :int16 0))
        (let [{:keys [frames written recovered]} (alsa/write! pcm buf frames)
              n (or frames written)]
          (println (str "  null pcm: wrote " n " frames"
                        (when recovered " (recovered from an overrun)")))
          (when-not (= 960 n)
            (throw (ex-info "writei answered something other than the frame count"
                            {:asked 960 :got n})))
          true)
        (finally (alsa/close! pcm))))))

(defn- check-enumeration
  "List the devices, which is what av.clj's cameras/microphones/speakers are.

  There is no assertion on the CONTENTS: this container has no camera, and
  which PCMs ALSA offers is a property of the machine rather than of this
  code. What is asserted is that enumeration returns without leaking or
  faulting and that every entry is shaped the way av.clj's `parse-devices`
  produced them — an :id to pass back, a :name to show, a :default? flag —
  because that shape is the contract the UI already reads."
  []
  (let [shaped? (fn [d] (and (string? (:id d)) (string? (:name d))
                             (contains? d :default?)))
        cams    (v4l2/devices)
        mics    (alsa/devices :capture)
        outs    (alsa/devices :playback)]
    (println "  cameras:" (count cams) (pr-str (mapv :name (take 2 cams))))
    (println "  capture:" (count mics) (pr-str (mapv :name (take 2 mics))))
    (println "  playback:" (count outs) (pr-str (mapv :name (take 2 outs))))
    (doseq [[what ds] [["camera" cams] ["capture" mics] ["playback" outs]]]
      (when-let [bad (first (remove shaped? ds))]
        (throw (ex-info (str what " device is not shaped like av.clj expects")
                        {:device bad}))))
    true))

(defn- i420-halves
  "An I420 frame whose left half is `lo` and right half `hi`.

  Flat frames are no use as a test: a decode that produced a uniform picture
  would pass every check a flat frame can make. Two halves also give each
  peer a distinguishable picture, which is what makes multi-peer testable —
  if the frames were identical there would be no way to tell a second peer
  from the first one counted twice."
  [a w h lo hi]
  (let [n (h264/i420-size w h)
        p (ffi/alloc a n)]
    (dotimes [y h]
      (dotimes [x w]
        (ffi/write (+ p (* y w) x) :uint8 (if (< x (quot w 2)) lo hi))))
    (dotimes [i (* 2 (quot (* w h) 4))]
      (ffi/write (+ p (* w h) i) :uint8 0x80))
    [p n]))

(defn- check-plane
  "Two peers' video, end to end through frq.av.plane.

  Nothing is configured: the plane watches the origin for ANNOUNCEMENTS,
  reads each peer's catalog for its video track name and container, and
  subscribes. Our own broadcast is announced back like anyone else's and
  becomes the self-view.

  The second broadcast stands in for another participant. It is published
  the same way a remote client would publish it and discovered the same way
  — the only thing it does not cross is the wire, which the connect check
  already covers.

  Each picture has a different contrast so a peer cannot be confused for the
  other, and the assertion is per peer: the right key, the right size, and
  the halves the right way round."
  []
  (ffi/with-arena [a]
    (let [w 64 h 64
          [ours _]  (i420-halves a w h 0x40 0xC0)
          [theirs _] (i420-halves a w h 0xC0 0x40)
          origin    (media/new-origin)]
      (plane/start! {:origin origin :path "/us" :source (fn [] [ours nil])
                     :width w :height h :fps 30 :bitrate 200000})
      ;; A second participant on the same origin, published exactly as a
      ;; remote one would be.
      (let [b2  (media/create-broadcast! origin "/them")
            p2  (media/publish-media! b2 "avc3")
            enc (h264/encoder {:width w :height h :fps 30 :bitrate 200000})]
        (try
          (let [deadline (+ (System/currentTimeMillis) 25000)]
            (loop [pumps 0 seen {}]
              ;; Keep the other peer publishing: a subscriber that arrives
              ;; after the first keyframe needs another one.
              (h264/force-keyframe! enc)
              (h264/encode! enc theirs (* pumps 33333)
                            (fn [p len _]
                              (when (pos? len)
                                (media/write-video-frame! p2 p len (* pumps 33333)))))
              (plane/pump!)
              (let [seen (reduce (fn [m f]
                                   (if (contains? m (:key f))
                                     m
                                     (let [at #(ffi/read (+ (:rgba f) (* 4 (+ (* 32 (:w f)) %))) :uint8)]
                                       (assoc m (:key f)
                                              {:w (:w f) :h (:h f)
                                               :left (at 8) :right (at 56)}))))
                                 seen (plane/poll-frames!))]
                (cond
                  (>= (count seen) 2)
                  (do
                    (doseq [[k v] seen]
                      (println "  " k (str (:w v) "x" (:h v))
                               "left" (:left v) "right" (:right v)))
                    (when-not (contains? seen "__local__")
                      (throw (ex-info "no self-view" {:keys (keys seen)})))
                    (let [local (get seen "__local__")
                          other (val (first (dissoc seen "__local__")))]
                      (when-not (< (:left local) (:right local))
                        (throw (ex-info "self-view halves are the wrong way round"
                                        {:frame local})))
                      (when-not (> (:left other) (:right other))
                        (throw (ex-info "peer halves are the wrong way round — the feeds are crossed"
                                        {:frame other}))))
                    true)

                  (> (System/currentTimeMillis) deadline)
                  (throw (ex-info "did not see two peers" {:pumps pumps :seen (keys seen)}))

                  :else (do (Thread/sleep 10) (recur (inc pumps) seen))))))
          (finally
            (h264/close! enc)
            (plane/stop!))))))) 

(defn- tone
  "20ms of a triangle at `amp`, int16 mono, in foreign memory."
  [a amp]
  (let [n audio/frame-samples
        p (ffi/alloc a (* 2 n))]
    (dotimes [i n]
      (let [phase (mod i 100)
            v (if (< phase 50)
                (- (* phase (quot (* 2 amp) 50)) amp)
                (- amp (* (- phase 50) (quot (* 2 amp) 50))))]
        (ffi/write (+ p (* 2 i)) :int16 v)))
    [p n]))

(defn- check-audio
  "A voice through the plane: Opus -> MoQ -> jitter buffer -> mix.

  The voice belongs to a SECOND peer, and it has to: the mixer excludes our
  own ring, because hearing your own microphone back is the thing headphones
  exist to prevent. A test that published only its own audio would be
  asserting on silence and calling it a bug.

  The assertion is amplitude. Opus is lossy and a triangle comes back
  rounded, but silence is unmistakable — and silence is exactly what a
  broken jitter buffer produces, whether it fills and never drains or drains
  before it fills.

  The pump count matters too: the ring holds `target-depth` frames before it
  plays anything, so a mix appearing on the first pump would mean the depth
  was not being honoured."
  []
  (ffi/with-arena [a]
    (let [[pcm _] (tone a 8000)
          origin  (media/new-origin)
          head-p  (ffi/alloc a 19)]
      (audio/opus-head! head-p 1)
      (plane/start! {:origin origin :path "/us"
                     :source (fn [] nil)          ; no camera in this check
                     :mic    (fn [] [pcm audio/frame-samples])
                     :width 64 :height 64 :channels 1})
      (let [b2  (media/create-broadcast! origin "/them")
            p2  (media/publish-media-bytes! b2 "opus" head-p 19)
            enc (opus/encoder audio/sample-rate 1 :voip)
            out (ffi/alloc a 4000)]
        (try
          (let [deadline (+ (System/currentTimeMillis) 25000)]
            (loop [pumps 0]
              ;; The other participant keeps talking.
              (let [n (opus/encode! enc pcm audio/frame-samples out 4000)]
                (when-not (opus/dtx? n)
                  (media/write-video-frame! p2 out n (* pumps 20000))))
              (plane/pump!)
              (let [mixed (plane/poll-audio!)]
                (cond
                  (and mixed (pos? (:peak mixed)))
                  (do (println "  mixed audio after" pumps "pumps, peak" (:peak mixed)
                               "over" (:samples mixed) "samples")
                      (when (< (:peak mixed) 500)
                        (throw (ex-info "the mix is effectively silent"
                                        {:peak (:peak mixed)})))
                      (when (< pumps 2)
                        (throw (ex-info "played before the jitter buffer filled"
                                        {:pumps pumps})))
                      true)

                  (> (System/currentTimeMillis) deadline)
                  (throw (ex-info "no audio came back through the plane" {:pumps pumps}))

                  :else (do (Thread/sleep 5) (recur (inc pumps)))))))
          (finally
            (opus/free-encoder! enc)
            (plane/stop!)))))))

(defn- check-session
  "The plane over a real QUIC session, not a local origin.

  A relay is stood up in-process — MoqServer with a self-signed certificate
  and one origin wired as both what it publishes and what it consumes, which
  is what makes it a relay rather than two unrelated halves. A client dials
  it over actual QUIC, and the plane runs on that session's publisher() and
  consumer() rather than on an origin it made itself.

  What this proves that the loopback checks cannot: that publish and
  discover being two DIFFERENT origins works, that a broadcast survives the
  wire, and that the announcement comes back through the relay rather than
  from an object we already had.

  Everything is polled, the relay included. Its accept has to be driven from
  the same loop as the client's connect, because the client cannot finish
  connecting until the relay accepts and there is no other thread to do it
  on — which is a fair model of the real thing, where glimmer's timer is
  the only clock this code gets."
  []
  (ffi/with-arena [a]
    (let [w 64 h 64
          [px _]  (i420-halves a w h 0x40 0xC0)
          relay   (media/new-origin)
          server  (client/new-server)]
      (client/server-bind! server "127.0.0.1:0")
      (client/server-tls-generate! server ["localhost"])
      (client/server-origin! server relay)
      (let [addr (settle! (client/server-listen! server) "listen" 10000
                          uniffi/lift-string)
            port (last (str/split addr #":"))
            fps  (client/server-fingerprints server)
            c    (client/new-client)]
        (println "  relay on" addr "fingerprint" (subs (first fps) 0 16))
        (client/set-tls-fingerprints! c fps)
        (let [connect  (client/connect! c (str "https://localhost:" port "/room"))
              incoming (client/server-accept! server)
              deadline (+ (System/currentTimeMillis) 25000)]
          (loop [req nil accepted nil sess nil]
            (let [;; The relay side: an incoming request, then accept it.
                  req      (or req (settle! incoming "accept" 0 media/lift-optional-handle))
                  accepted (or accepted (when req (client/accept-request! req)))
                  _        (when accepted (settle! accepted "request accept" 0 nil))
                  ;; The client side.
                  sess     (or sess (settle! connect "connect" 0 nil))]
              (cond
                sess
                (do
                  (println "  connected over QUIC")
                  (try
                    (plane/start! {:origin   (client/session-publisher sess)
                                   :discover (client/session-consumer sess)
                                   :session  sess
                                   :path "/us" :source (fn [] [px nil])
                                   :width w :height h :fps 30 :bitrate 200000})
                    (let [d2 (+ (System/currentTimeMillis) 20000)]
                      (loop [pumps 0]
                        (plane/pump!)
                        (if-let [f (first (plane/poll-frames!))]
                          (do (println "  frame back through the relay after" pumps
                                       "pumps:" (:w f) "x" (:h f) (pr-str (:key f)))
                              (when-not (and (= w (:w f)) (= h (:h f)))
                                (throw (ex-info "wrong size over the wire" {:frame f})))
                              true)
                          (if (> (System/currentTimeMillis) d2)
                            (throw (ex-info "no frame came back over the session"
                                            {:pumps pumps}))
                            (do (Thread/sleep 10) (recur (inc pumps)))))))
                    (finally
                      (plane/stop!)
                      (client/server-cancel! server))))

                (> (System/currentTimeMillis) deadline)
                (throw (ex-info "the session never came up"
                                {:request req :accepted (some? accepted)}))

                :else (do (Thread/sleep 10) (recur req accepted sess))))))))))

(defn- check-wired-devices
  "The plane driven by real device objects rather than test thunks.

  ALSA's `null` on both ends, and that is a limit of this machine rather
  than a choice: the sound hardware is held by PipeWire on the host, and
  PipeWire's own socket is not reachable from inside this container, so
  `default` and `hw:1,0` both refuse. `null` is a real PCM opened through
  the real binding — it proves the wiring, the frame arithmetic and the
  teardown, and it cannot prove that a microphone sounds like anything.

  The camera is not here at all: there is no /dev/video* and no privilege to
  load the kernel's virtual one. `frq.capture.source/camera` is written and
  unexercised, and this test says so rather than implying otherwise.

  What IS asserted: that a device-shaped mic drives the outbound half, that
  a speaker sink is written to without raising, and that stop! releases
  both. A leak here would show up as `Device or resource busy` on the second
  run, which is why the check runs the whole cycle twice."
  []
  (dotimes [round 2]
    (let [origin (media/new-origin)]
      (plane/start! {:origin origin :path "/us"
                     :source (fn [] nil)
                     :mic-device "null"
                     :speaker-device "null"
                     :width 64 :height 64 :channels 1})
      (try
        (dotimes [_ 5] (plane/pump!))
        (println (str "  round " (inc round) ": mic and speaker opened, pumped, closed"))
        (finally (plane/stop!)))))
  ;; And the camera path as far as it goes on a machine with no camera:
  ;; enumeration is empty and opening one raises rather than pretending.
  (let [cams (v4l2/devices)]
    (println "  cameras available:" (count cams))
    (when (seq cams)
      (let [c (source/camera (:id (first cams)) {:width 640 :height 480})]
        (println "  opened" (:id (first cams)) (:width c) "x" (:height c))
        ((:close! c)))))
  true)

(defn- check-status
  "The three transitions frq.av reads: live, failed, ended.

  :live is asserted on a plain local plane — it carries has-camera? and
  has-mic?, which is what the UI shows before a single frame arrives.

  :ended and :failed need a session to lose, so the relay from the session
  check is stood up again and then CANCELLED underneath a running plane.
  That is the case that matters: not a call the person hung up, but one
  that went away, which is the whole reason poll-status! exists rather than
  frq.av inferring things from frames stopping.

  Whether the drop reads as :ended or :failed depends on how the far side
  goes — a relay cancelled mid-session may close cleanly or not — so both
  are accepted here. What is NOT accepted is silence: a call that ends with
  no transition at all is one where the person is left looking at a frozen
  picture."
  []
  (ffi/with-arena [a]
    ;; 1. :live, with the flags.
    (let [origin (media/new-origin)]
      (plane/start! {:origin origin :path "/us"
                     :source (fn [] nil) :mic (fn [] nil)
                     :width 64 :height 64 :channels 1})
      (let [[ev] (plane/poll-status!)]
        (println "  live event:" (pr-str ev))
        (when-not (= :live (:code ev))
          (throw (ex-info "no :live on start" {:event ev})))
        (when-not (and (:has-camera? ev) (:has-mic? ev))
          (throw (ex-info "flags do not reflect the sources given" {:event ev})))
        (when (seq (plane/poll-status!))
          (throw (ex-info "poll-status! did not drain" {}))))
      (plane/stop!))

    ;; 2. a session lost underneath us.
    (let [[px _]  (i420-halves a 64 64 0x40 0xC0)
          relay   (media/new-origin)
          server  (client/new-server)]
      (client/server-bind! server "127.0.0.1:0")
      (client/server-tls-generate! server ["localhost"])
      (client/server-origin! server relay)
      (let [addr (settle! (client/server-listen! server) "listen" 10000
                          uniffi/lift-string)
            port (last (str/split addr #":"))
            fps  (client/server-fingerprints server)
            c    (client/new-client)]
        (client/set-tls-fingerprints! c fps)
        (let [connect  (client/connect! c (str "https://localhost:" port "/room"))
              incoming (client/server-accept! server)
              deadline (+ (System/currentTimeMillis) 25000)]
          (loop [req nil accepted nil srv nil sess nil]
            (let [req      (or req (settle! incoming "accept" 0 media/lift-optional-handle))
                  accepted (or accepted (when req (client/accept-request! req)))
                  ;; The relay's OWN side of the session, kept rather than
                  ;; dropped: cancelling the server only stops it accepting
                  ;; new connections, and an established QUIC session then
                  ;; sits there until its idle timeout — half a minute of
                  ;; a frozen picture. What a peer hanging up actually
                  ;; looks like is this session being cancelled.
                  srv      (or srv (when accepted
                                     (settle! accepted "request accept" 0 nil)))
                  sess     (or sess (settle! connect "connect" 0 nil))]
              (cond
                (and sess srv)
                (do
                  (plane/start! {:origin   (client/session-publisher sess)
                                 :discover (client/session-consumer sess)
                                 :session  sess
                                 :path "/us" :source (fn [] [px nil])
                                 :width 64 :height 64 :fps 30 :bitrate 200000})
                  (plane/poll-status!)              ; drain the :live
                  (dotimes [_ 10] (plane/pump!) (Thread/sleep 10))
                  (println "  dropping the far side under a live plane")
                  (client/cancel! srv 0)
                  (client/server-cancel! server)
                  (let [d2 (+ (System/currentTimeMillis) 20000)]
                    (loop [pumps 0]
                      (plane/pump!)
                      (let [evs (plane/poll-status!)]
                        (cond
                          (seq evs)
                          (do (println "  after the drop:" (pr-str evs))
                              (when-not (some #{:ended :failed} (map :code evs))
                                (throw (ex-info "the drop produced no ending"
                                                {:events evs})))
                              (plane/stop!)
                              true)

                          (> (System/currentTimeMillis) d2)
                          (do (plane/stop!)
                              (throw (ex-info "the session went away silently"
                                              {:pumps pumps})))

                          :else (do (Thread/sleep 10) (recur (inc pumps))))))))

                (> (System/currentTimeMillis) deadline)
                (throw (ex-info "the session never came up" {}))

                :else (do (Thread/sleep 10) (recur req accepted srv sess))))))))))

(defn -main [& _]
  (println "libmoq_ffi smoke test")
  (let [steps [["contract" check-contract]
               ["handle"   check-handle]
               ["string"   check-string]
               ["connect"  check-connect]
               ["media"    check-media]
               ["opus"     check-opus]
               ["h264"     check-h264]
               ["v4l2"     check-v4l2-layouts]
               ["alsa"     check-alsa]
               ["devices"  check-enumeration]
               ["plane"    check-plane]
               ["audio"    check-audio]
               ["session"  check-session]
               ["wired"    check-wired-devices]
               ["status"   check-status]]]
    (doseq [[name f] steps]
      (println (str name ":"))
      (f))
    (println "all ok")))
