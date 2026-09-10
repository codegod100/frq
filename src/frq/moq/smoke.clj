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
  (:require [frq.moq.uniffi :as uniffi]
            [frq.moq.raw :as raw]
            [frq.moq.client :as client]
            [frq.moq.media :as media]
            [frq.codec.opus :as opus]
            [frq.codec.h264 :as h264]
            [frq.capture.v4l2 :as v4l2]
            [frq.capture.alsa :as alsa]
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
  (let [deadline (+ (System/currentTimeMillis) ms)]
    (loop []
      (cond
        (uniffi/settled? fut) (if lift
                                (uniffi/complete! fut lift)
                                (uniffi/complete! fut))
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
               ["alsa"     check-alsa]]]
    (doseq [[name f] steps]
      (println (str name ":"))
      (f))
    (println "all ok")))
