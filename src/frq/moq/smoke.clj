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

(defn -main [& _]
  (println "libmoq_ffi smoke test")
  (let [steps [["contract" check-contract]
               ["handle"   check-handle]
               ["string"   check-string]
               ["connect"  check-connect]
               ["media"    check-media]]]
    (doseq [[name f] steps]
      (println (str name ":"))
      (f))
    (println "all ok")))
