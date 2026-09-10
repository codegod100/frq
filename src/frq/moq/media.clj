(ns frq.moq.media
  "Broadcasts, media tracks, and the frames that cross them.

  An origin is the piece that makes this testable without a network. A
  `MoqOriginProducer` is a plain constructor, not something a session hands
  out: create one, create a broadcast under it, publish a media track, and
  `consume` gives you the subscriber's side of the very same broadcast. No
  QUIC, no relay, no second process — which is how `frq.moq.smoke` can put a
  frame in and take the same frame out.

  Over a session the shapes are identical; only where the origin comes from
  changes, so what is exercised locally is what runs over the wire.

  ON FRAME PAYLOADS. `frame-payload` answers a jolt string, and that is a
  DEBUGGING affordance, not the path a real frame should take. UniFFI gives
  Bytes and String the same wire shape — an i32 length and that many bytes —
  so a payload survives the trip only while it happens to be text. H.264 is
  not text. `frq.av`'s rule is that a video frame goes from the decoder's
  buffer to the texture as a pointer and never becomes a jolt value at all,
  and honouring that here means reading the payload's address out of the
  buffer and handing it on — which is what the real subscribe path will do,
  and what this namespace does not do yet."
  (:require [frq.moq.uniffi :as uniffi]
            [frq.moq.raw :as raw]
            [jolt.ffi :as ffi]))

(defn- lowered
  "Run `f` with a RustBuffer holding `ops`."
  [ops f]
  (ffi/with-arena [a]
    (let [buf (ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
      (uniffi/lower-buffer buf ops)
      (f buf))))

;; --- containers --------------------------------------------------------------

(def containers
  "MoqContainer, as UniFFI numbers it. LEGACY and LOC carry nothing; CMAF
  carries its init segment, which `container-ops` does not build yet."
  {:legacy 1 :cmaf 2 :loc 3})

(defn container-ops [kind]
  (let [v (or (containers kind)
              (throw (ex-info "unknown MoqContainer" {:kind kind
                                                      :known (keys containers)})))]
    (when (= kind :cmaf)
      (throw (ex-info "CMAF needs its init segment, which is not built here" {})))
    [[:i32 v]]))

;; --- origins and broadcasts --------------------------------------------------

(defn new-origin
  "A MoqOriginProducer with default options (no cache cap)."
  []
  (lowered [[:u8 0]]                    ; MoqOriginOptions{cache_capacity_bytes: None}
           (fn [buf]
             (uniffi/with-out-status
               #(raw/constructor-moqoriginproducer-new buf %)))))

(defn create-broadcast!
  "A MoqBroadcastProducer at `path` under this origin.

  `path` goes through `lower-string`, not the record encoder: see the note on
  `subscribe-media!` about which strings carry a length and which do not."
  [origin path]
  (let [h (uniffi/with-out-status #(raw/clone-moqoriginproducer origin %))]
    (ffi/with-arena [a]
      (let [buf (uniffi/lower-string
                  (ffi/alloc a (ffi/layout-size uniffi/rust-buffer)) path)]
        (uniffi/with-out-status
          #(raw/method-moqoriginproducer-create-broadcast h buf %))))))

(defn broadcast-consumer
  "The subscriber's side of a broadcast we produce."
  [broadcast]
  (let [h (uniffi/with-out-status #(raw/clone-moqbroadcastproducer broadcast %))]
    (uniffi/with-out-status #(raw/method-moqbroadcastproducer-consume h %))))

;; --- discovery --------------------------------------------------------------
;; How a peer is FOUND, rather than known. `subscribe-media!` needs a path and
;; a track name; announcements are where those come from when the other side
;; of the call is somebody else's client rather than a broadcast we made.

(defn origin-consumer
  "The subscriber's side of an origin."
  [origin]
  (let [h (uniffi/with-out-status #(raw/clone-moqoriginproducer origin %))]
    (uniffi/with-out-status #(raw/method-moqoriginproducer-consume h %))))

(defn announced!
  "Watch for broadcasts whose path starts with `prefix`; answers a MoqAnnounced.

  An empty prefix watches everything on the origin, which in a call is what
  you want: every participant is a broadcast and none of their paths are
  known in advance."
  [origin-consumer prefix]
  (let [h (uniffi/with-out-status #(raw/clone-moqoriginconsumer origin-consumer %))]
    (ffi/with-arena [a]
      (let [buf (uniffi/lower-string
                  (ffi/alloc a (ffi/layout-size uniffi/rust-buffer)) prefix)]
        (uniffi/with-out-status
          #(raw/method-moqoriginconsumer-announced h buf %))))))

(defn next-announcement!
  "Ask for the next announcement; answers an :rb future.

  It settles to an Optional<MoqAnnouncement> — absent when the origin has
  closed, which is the end of the watch rather than an error."
  [announced]
  (let [h (uniffi/with-out-status #(raw/clone-moqannounced announced %))]
    (-> (raw/method-moqannounced-next h)
        (uniffi/start-future :rb))))

(defn lift-optional-handle
  "Read an Optional<interface> from a settled :rb buffer as a handle.

  An interface crosses as a u64 the far side has already cloned for us, so
  freeing the buffer it arrived in does not touch it. Announcements,
  requests and anything else optional-and-opaque come back this way."
  [rb-ptr]
  (let [len  (ffi/read-field rb-ptr uniffi/rust-buffer [:len])
        data (ffi/read-field rb-ptr uniffi/rust-buffer [:data])
        v    (when (and (pos? len) (not (ffi/null? data)))
               (uniffi/r-optional! (uniffi/reader data len) uniffi/r-u64!))]
    (uniffi/with-out-status #(raw/rustbuffer-free rb-ptr %))
    v))

(defn lift-announcement
  "Read an Optional<MoqAnnouncement> from a settled :rb buffer.

  Answers the announcement's HANDLE, which outlives the buffer — an interface
  crosses as a u64 the far side has already cloned for us, so freeing the
  buffer it arrived in does not touch it."
  [rb-ptr]
  (let [len  (ffi/read-field rb-ptr uniffi/rust-buffer [:len])
        data (ffi/read-field rb-ptr uniffi/rust-buffer [:data])
        v    (when (and (pos? len) (not (ffi/null? data)))
               (let [c (uniffi/reader data len)]
                 (uniffi/r-optional! c uniffi/r-u64!)))]
    (uniffi/with-out-status #(raw/rustbuffer-free rb-ptr %))
    v))

(defn announcement-path
  [ann]
  (let [h (uniffi/with-out-status #(raw/clone-moqannouncement ann %))]
    (ffi/with-arena [a]
      (let [out (ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
        (uniffi/with-out-status #(raw/method-moqannouncement-path out h %))
        (uniffi/lift-string out)))))

(defn announcement-broadcast
  "The MoqBroadcastConsumer this announcement is for."
  [ann]
  (let [h (uniffi/with-out-status #(raw/clone-moqannouncement ann %))]
    (uniffi/with-out-status #(raw/method-moqannouncement-broadcast h %))))

;; --- the catalog ------------------------------------------------------------
;; What a peer's broadcast says it contains. Two things come out of it that
;; cannot be guessed from the outside: the track NAMES, and each track's
;; CONTAINER — which is the LOC-versus-LEGACY question that answers
;; `mux: loc: malformed loc properties` when got wrong.

(def ^:private container-names
  (into {} (map (fn [[k v]] [v k])) containers))

(defn- r-dimensions [c]
  {:width (uniffi/r-i32! c) :height (uniffi/r-i32! c)})

(defn- r-container [c]
  (let [v (uniffi/r-i32! c)]
    (when (= v (containers :cmaf)) (uniffi/r-bytes-span! c))  ; init blob, skipped
    (container-names v :unknown)))

(defn- r-video [c]
  {:codec       (uniffi/r-string! c)
   :description (uniffi/r-optional! c uniffi/r-bytes-span!)
   :coded       (uniffi/r-optional! c r-dimensions)
   :aspect      (uniffi/r-optional! c r-dimensions)
   :bitrate     (uniffi/r-optional! c uniffi/r-u64!)
   :stalled     (uniffi/r-bool! c)
   :framerate   (uniffi/r-optional! c uniffi/r-f64!)
   :container   (r-container c)})

(defn- r-audio [c]
  {:codec        (uniffi/r-string! c)
   :description  (uniffi/r-optional! c uniffi/r-bytes-span!)
   :sample-rate  (uniffi/r-i32! c)
   :channels     (uniffi/r-i32! c)
   :bitrate      (uniffi/r-optional! c uniffi/r-u64!)
   :container    (r-container c)})

(defn next-catalog!
  "Ask for the next catalog update; answers an :rb future."
  [catalog-consumer]
  (let [h (uniffi/with-out-status #(raw/clone-moqcatalogconsumer catalog-consumer %))]
    (-> (raw/method-moqcatalogconsumer-next h)
        (uniffi/start-future :rb))))

(defn lift-catalog
  "Read an Optional<MoqCatalog> from a settled :rb buffer.

  Every field is read even though only `:video` is used yet: the fields are
  positional in the buffer, so skipping one means parsing it anyway, and
  half-parsing a record is how the next field comes out as nonsense."
  [rb-ptr]
  (let [len  (ffi/read-field rb-ptr uniffi/rust-buffer [:len])
        data (ffi/read-field rb-ptr uniffi/rust-buffer [:data])
        v    (when (and (pos? len) (not (ffi/null? data)))
               (let [c (uniffi/reader data len)]
                 (uniffi/r-optional!
                   c (fn [c]
                       {:video    (uniffi/r-map! c r-video)
                        :audio    (uniffi/r-map! c r-audio)
                        :display  (uniffi/r-optional! c r-dimensions)
                        :rotation (uniffi/r-optional! c uniffi/r-f64!)
                        :flip     (uniffi/r-optional! c uniffi/r-bool!)
                        :sections (uniffi/r-map! c uniffi/r-string!)}))))]
    (uniffi/with-out-status #(raw/rustbuffer-free rb-ptr %))
    v))

(defn subscribe-catalog!
  "Watch a broadcast's catalog; answers a future settling to a
  MoqCatalogConsumer.

  What names a peer's tracks. `subscribe-media!` wants a track name, and on a
  broadcast we did not publish there is nothing else to learn it from."
  [broadcast-consumer]
  (let [h (uniffi/with-out-status #(raw/clone-moqbroadcastconsumer broadcast-consumer %))]
    (-> (raw/method-moqbroadcastconsumer-subscribe-catalog h)
        (uniffi/start-future :u64))))

;; --- publishing --------------------------------------------------------------

(defn publish-media!
  "Publish a media track and answer its MoqMediaProducer.

  `init` is a MoqInit: a format string, an init blob, and an optional video
  hint. The blob goes out through the :string op because UniFFI lowers Bytes
  and String identically — an i32 length and that many bytes."
  ([broadcast format] (publish-media! broadcast format ""))
  ([broadcast format init-data]
   (let [h (uniffi/with-out-status #(raw/clone-moqbroadcastproducer broadcast %))]
     (lowered [[:string format] [:string init-data] [:u8 0]]
              (fn [buf]
                (uniffi/with-out-status
                  #(raw/method-moqbroadcastproducer-publish-media h buf %)))))))

(defn publish-media-bytes!
  "Publish a media track whose init blob is RAW bytes.

  `publish-media!` above takes the blob as a string, which is fine for the
  empty one a video track uses and wrong for an OpusHead — that is 19 bytes
  of little-endian header with interior zeros, and routing it through a jolt
  string would not survive."
  [broadcast format ptr len]
  (let [h (uniffi/with-out-status #(raw/clone-moqbroadcastproducer broadcast %))]
    (lowered [[:string format] [:bytes [ptr len]] [:u8 0]]
             (fn [buf]
               (uniffi/with-out-status
                 #(raw/method-moqbroadcastproducer-publish-media h buf %))))))

(defn producer-name
  "The track name the object chose for this producer — what a subscriber asks
  for by name."
  [producer]
  (let [h (uniffi/with-out-status #(raw/clone-moqmediaproducer producer %))]
    (ffi/with-arena [a]
      (let [out (ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
        (uniffi/with-out-status #(raw/method-moqmediaproducer-name out h %))
        (uniffi/lift-string out)))))

(defn write-frame!
  "Write one MoqFrame to a media producer: a payload and a microsecond stamp.

  MoqFrame, NOT MoqMediaFrame. The two names differ by one word and by one
  field — what a consumer hands back carries a `keyframe` flag, and what a
  producer takes does not, because the container works that out from the
  bitstream. Sending the extra byte is not an ABI error: the object lifts the
  record, finds a byte left over, and panics with `junk data left in buffer`."
  [producer payload timestamp-us]
  (let [h (uniffi/with-out-status #(raw/clone-moqmediaproducer producer %))]
    (lowered [[:string payload] [:u64 timestamp-us]]
             (fn [buf]
               (uniffi/with-out-status
                 #(raw/method-moqmediaproducer-write-frame h buf %)))))
  nil)

;; --- opaque tracks -----------------------------------------------------------
;; The same broadcast, without a codec in the way. `publish_track` and
;; `subscribe_track` move plain byte payloads and parse nothing, which is what
;; a round trip can actually be checked against: a media track declares a
;; format, and `avc3` means the container really does try to read Annex B out
;; of whatever is handed to it.

(defn publish-track!
  "Publish an opaque track by name; answers a MoqTrackProducer."
  [broadcast name]
  (let [h (uniffi/with-out-status #(raw/clone-moqbroadcastproducer broadcast %))]
    (ffi/with-arena [a]
      (let [cell #(ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
        (uniffi/with-out-status
          #(raw/method-moqbroadcastproducer-publish-track
             h
             (uniffi/lower-string (cell) name)
             (uniffi/lower-buffer (cell) [[:u8 0]])   ; Optional<MoqTrackInfo>
             %))))))

(defn write-track-frame!
  "Write one MoqFrame to an opaque track producer."
  [producer payload timestamp-us]
  (let [h (uniffi/with-out-status #(raw/clone-moqtrackproducer producer %))]
    (lowered [[:string payload] [:u64 timestamp-us]]
             (fn [buf]
               (uniffi/with-out-status
                 #(raw/method-moqtrackproducer-write-frame h buf %)))))
  nil)

(defn subscribe-track!
  "Subscribe to an opaque track; answers a future settling to a
  MoqTrackConsumer."
  [broadcast-consumer name]
  (let [h (uniffi/with-out-status #(raw/clone-moqbroadcastconsumer broadcast-consumer %))]
    (ffi/with-arena [a]
      (let [cell #(ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
        (-> (raw/method-moqbroadcastconsumer-subscribe-track
              h
              (uniffi/lower-string (cell) name)
              (uniffi/lower-buffer (cell) [[:u8 0]]))  ; Optional<MoqSubscription>
            (uniffi/start-future :u64))))))

(defn read-frame!
  "Ask an opaque track for its next frame; answers an :rb future."
  [consumer]
  (let [h (uniffi/with-out-status #(raw/clone-moqtrackconsumer consumer %))]
    (-> (raw/method-moqtrackconsumer-read-frame h)
        (uniffi/start-future :rb))))

(defn lift-plain-frame
  "Read an Optional<MoqFrame> out of a settled :rb buffer, and free it."
  [rb-ptr]
  (let [len  (ffi/read-field rb-ptr uniffi/rust-buffer [:len])
        data (ffi/read-field rb-ptr uniffi/rust-buffer [:data])
        v    (when (and (pos? len) (not (ffi/null? data)))
               (let [c (uniffi/reader data len)]
                 (uniffi/r-optional!
                   c (fn [c]
                       {:payload      (uniffi/r-string! c)
                        :timestamp-us (uniffi/r-u64! c)}))))]
    (uniffi/with-out-status #(raw/rustbuffer-free rb-ptr %))
    v))

;; --- subscribing -------------------------------------------------------------

(defn subscribe-media!
  "Subscribe to `name`; answers a future that settles to a MoqMediaConsumer.

  THREE buffers, not one. Each argument of a UniFFI method is lowered into a
  RustBuffer of its own — the concatenation that a record's fields go through
  is a shape that stops at the record boundary.

  And the name is lowered by `lower-string`, NOT as [[:string name]]. Where a
  string sits decides whether it carries its own length:

    * a TOP-LEVEL string argument is bare UTF-8, and the RustBuffer's own
      `len` is the length;
    * a string INSIDE a record, enum or optional is prefixed with an i32 byte
      count, because the buffer's length no longer delimits it.

  Both are `String` on the Rust side and the difference is invisible in the
  signature. Getting it backwards does not fail at the ABI — the four prefix
  bytes simply become part of the name, and the object answers `not found`
  for a track that is plainly there."
  [broadcast-consumer name container]
  (let [h (uniffi/with-out-status #(raw/clone-moqbroadcastconsumer broadcast-consumer %))]
    (ffi/with-arena [a]
      (let [cell #(ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
        (-> (raw/method-moqbroadcastconsumer-subscribe-media
              h
              (uniffi/lower-string (cell) name)
              (uniffi/lower-buffer (cell) (container-ops container))
              (uniffi/lower-buffer (cell) [[:u8 0]]))  ; Optional::None
            (uniffi/start-future :u64))))))

(defn next-frame!
  "Ask for the next frame; answers a future.

  It settles to a RustBuffer holding an Optional<MoqMediaFrame> — absent when
  the track has ended — so it is an :rb future, not a :u64 one."
  [consumer]
  (let [h (uniffi/with-out-status #(raw/clone-moqmediaconsumer consumer %))]
    (-> (raw/method-moqmediaconsumer-next h)
        (uniffi/start-future :rb))))

(defn lift-frame
  "Read an Optional<MoqMediaFrame> out of a settled :rb future's buffer, and
  free the buffer. nil means the track ended."
  [rb-ptr]
  (let [len  (ffi/read-field rb-ptr uniffi/rust-buffer [:len])
        data (ffi/read-field rb-ptr uniffi/rust-buffer [:data])
        v    (when (and (pos? len) (not (ffi/null? data)))
               (let [c (uniffi/reader data len)]
                 (uniffi/r-optional!
                   c (fn [c]
                       {:payload      (uniffi/r-string! c)
                        :timestamp-us (uniffi/r-u64! c)
                        :keyframe     (uniffi/r-bool! c)}))))]
    (uniffi/with-out-status #(raw/rustbuffer-free rb-ptr %))
    v))

;; --- encoded frames --------------------------------------------------------
;; No publish_video or publish_audio here: those are moq-ffi's `video` and
;; `audio` features, which the release object is built without. Encoding
;; happens on this side, against libopus and openh264 directly, and what
;; crosses is an already-encoded frame.
;;
;; A video track publishes as LEGACY. Subscribing to one with LOC answers
;; `mux: loc: malformed loc properties` — a message about properties, from a
;; mismatch about containers — so it is written down here rather than
;; rediscovered. Reading the catalog is the honest way to learn it.

(def video-container :legacy)

(defn write-video-frame!
  "Write an ALREADY-ENCODED frame to a media producer, from foreign memory.

  The `write-frame!` above takes a jolt string, which is fine for a test
  payload and wrong for H.264. This takes [pointer length] and copies the
  bytes straight into the buffer, so an encoded frame goes from the
  encoder's output to the wire without becoming a jolt value."
  [producer ptr len timestamp-us]
  (let [h (uniffi/with-out-status #(raw/clone-moqmediaproducer producer %))]
    (lowered [[:bytes [ptr len]] [:u64 timestamp-us]]
             (fn [buf]
               (uniffi/with-out-status
                 #(raw/method-moqmediaproducer-write-frame h buf %)))))
  nil)

(defn lift-media-frame
  "Read an Optional<MoqMediaFrame>, handing the payload to `use-payload` as a
  BORROWED [pointer length] span.

  The span is valid only inside this call: the buffer is freed on the way out.
  That is the shape on purpose — it is what lets an encoded frame go straight
  on to a texture, the way frq.av already moves one, instead of being copied
  into a jolt value first."
  [rb-ptr use-payload]
  (let [len  (ffi/read-field rb-ptr uniffi/rust-buffer [:len])
        data (ffi/read-field rb-ptr uniffi/rust-buffer [:data])
        v    (when (and (pos? len) (not (ffi/null? data)))
               (let [c (uniffi/reader data len)]
                 (uniffi/r-optional!
                   c (fn [c]
                       (let [span (uniffi/r-bytes-span! c)
                             ts   (uniffi/r-u64! c)
                             kf   (uniffi/r-bool! c)]
                         {:payload      (use-payload (:ptr span) (:len span))
                          :bytes        (:len span)
                          :timestamp-us ts
                          :keyframe     kf})))))]
    (uniffi/with-out-status #(raw/rustbuffer-free rb-ptr %))
    v))
