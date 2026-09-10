(ns frq.codec.opus
  "Opus, bound to libopus.

  This is what the media plane's audio half becomes on this side of the port.
  libmoq_ffi carries MoQ over QUIC and nothing else — moq-ffi's `audio`
  feature, which would have brought Opus with it, costs a 1062-crate build —
  so the codec is linked where it has always lived, in a C library with a flat
  API and a twenty-year-old ABI.

  Two things about that API shape the binding.

  **PCM is int16, interleaved, and never a jolt value.** `encode!` and
  `decode!` take and answer [pointer length] spans of foreign memory, the same
  as `frq.moq.media`'s frame path. A 20ms stereo frame at 48kHz is 1920
  samples; turning that into a jolt vector twice per frame, fifty times a
  second, is work with nothing to show for it, and `frq.av`'s rule already
  says audio and video move as pointers.

  **A frame is not any length you like.** Opus encodes exactly 2.5, 5, 10, 20,
  40 or 60ms, and `frame-size` is a count of samples PER CHANNEL, not bytes
  and not interleaved samples. Handing it the interleaved count is the classic
  mistake: at stereo it asks for twice the duration, which is a valid frame
  size, so nothing raises and the audio simply runs fast."
  (:require [jolt.ffi :as ffi]))

;; --- constants ---------------------------------------------------------------

(def ^:const ok 0)

(def applications
  "What the encoder is being asked to optimise for. :voip is what a call
  wants — it favours speech intelligibility over musical fidelity."
  {:voip 2048 :audio 2049 :low-delay 2051})

(def ^:private errors
  {0 :ok -1 :bad-arg -2 :buffer-too-small -3 :internal-error
   -4 :invalid-packet -5 :unimplemented -6 :invalid-state -7 :alloc-fail})

(def ^:const set-bitrate-request 4002)

;; Sample counts PER CHANNEL for one frame at 48kHz, by frame duration.
(def frame-samples-48k
  {2.5 120, 5 240, 10 480, 20 960, 40 1920, 60 2880})

;; --- the entry points --------------------------------------------------------

(ffi/defcfn raw-encoder-create "opus_encoder_create"
  [:int32 :int :int :pointer] :pointer)
(ffi/defcfn raw-encoder-destroy "opus_encoder_destroy" [:pointer] :void)
(ffi/defcfn raw-encode "opus_encode"
  [:pointer :pointer :int :pointer :int32] :int32)
;; Variadic: the CTL request decides the tail. Declared with the one tail
;; shape this namespace uses — an int32 — rather than a bare :&, so it costs
;; no compile at the first call.
(ffi/defcfn raw-encoder-ctl "opus_encoder_ctl" [:pointer :int :& :int32] :int)

(ffi/defcfn raw-decoder-create "opus_decoder_create" [:int32 :int :pointer] :pointer)
(ffi/defcfn raw-decoder-destroy "opus_decoder_destroy" [:pointer] :void)
(ffi/defcfn raw-decode "opus_decode"
  [:pointer :pointer :int32 :pointer :int :int] :int)

(ffi/defcfn raw-strerror "opus_strerror" [:int] :string)

;; --- errors ------------------------------------------------------------------

(defn- check!
  "libopus answers a negative int for every failure, in every function that
  returns one. There is no errno and no out-parameter to consult except on the
  constructors, so this is the whole error protocol."
  [n what]
  (if (neg? n)
    (throw (ex-info (str "opus: " what ": " (raw-strerror n))
                    {:code n :error (errors n :unknown) :op what}))
    n))

;; --- encoding ----------------------------------------------------------------

(defn encoder
  "An Opus encoder. `sample-rate` is one of 8000, 12000, 16000, 24000, 48000."
  ([] (encoder 48000 1 :voip))
  ([sample-rate channels application]
   (ffi/with-arena [a]
     (let [err (ffi/alloc a 4)
           enc (raw-encoder-create sample-rate channels
                                   (or (applications application)
                                       (throw (ex-info "unknown opus application"
                                                       {:got application
                                                        :known (keys applications)})))
                                   err)]
       (check! (ffi/read err :int32) "encoder_create")
       (when (ffi/null? enc)
         (throw (ex-info "opus: encoder_create answered NULL" {})))
       enc))))

(defn set-bitrate!
  "Bits per second across all channels."
  [enc bps]
  (check! (raw-encoder-ctl enc set-bitrate-request bps) "set_bitrate")
  nil)

(defn encode!
  "Encode one frame; answers the number of bytes written into `out`.

  `pcm` is a pointer to interleaved int16 samples and `samples-per-channel`
  counts them PER CHANNEL — see the namespace docstring on why that
  distinction bites silently rather than loudly.

  A return of 2 bytes or fewer is not an error: it is DTX, the encoder saying
  this frame is silence and need not be sent at all."
  [enc pcm samples-per-channel out out-capacity]
  (check! (raw-encode enc pcm samples-per-channel out out-capacity) "encode"))

(defn dtx?
  "Did `encode!` decide the frame was not worth sending?"
  [written]
  (<= written 2))

(defn free-encoder! [enc] (raw-encoder-destroy enc) nil)

;; --- decoding ----------------------------------------------------------------

(defn decoder
  ([] (decoder 48000 1))
  ([sample-rate channels]
   (ffi/with-arena [a]
     (let [err (ffi/alloc a 4)
           dec (raw-decoder-create sample-rate channels err)]
       (check! (ffi/read err :int32) "decoder_create")
       (when (ffi/null? dec)
         (throw (ex-info "opus: decoder_create answered NULL" {})))
       dec))))

(defn decode!
  "Decode one packet into `pcm`; answers samples decoded PER CHANNEL.

  `capacity-per-channel` is how much room `pcm` has, again per channel. Pass a
  nil packet to conceal a lost one — that is what Opus's PLC is, and it is why
  `data` is allowed to be NULL where most C APIs would refuse."
  [dec data len pcm capacity-per-channel]
  (check! (raw-decode dec (or data ffi/null) (if data len 0)
                      pcm capacity-per-channel 0)
          "decode"))

(defn free-decoder! [dec] (raw-decoder-destroy dec) nil)
