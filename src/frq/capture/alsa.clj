(ns frq.capture.alsa
  "Audio devices, through libasound.

  The last of the four C libraries the media plane needs, and the least
  eventful: ALSA has a flat C API, no vtable and no ioctl arithmetic. What it
  does have is two APIs, and this binds the small one — `snd_pcm_set_params`
  configures format, access, channels, rate, resampling and latency in a
  single call, where the general path is a `snd_pcm_hw_params_t` allocated by
  the library and poked field by field through thirty accessors. The small one
  is enough for a call: interleaved S16 at a fixed rate is what Opus wants on
  one side and what a device gives on the other.

  READS ARE BLOCKING and counted in FRAMES, not bytes and not samples. A
  frame is one sample per channel, so 960 frames of stereo S16 is 3840 bytes;
  passing a byte count asks for four times the audio and blocks for four
  times as long, which looks like a slow device rather than a bug.

  RECOVERY IS EXPECTED. An overrun on capture is normal on a busy machine and
  is not a failure — `snd_pcm_recover` puts the stream back and the next read
  continues. `read!` does that itself and reports the loss rather than
  raising, because a dropped buffer is a thing a call survives."
  (:require [jolt.ffi :as ffi]))

(def ^:const format-s16-le 2)
(def ^:const access-rw-interleaved 3)
(def streams {:playback 0 :capture 1})

(ffi/defcfn raw-open "snd_pcm_open" [:pointer :string :int :int] :int)
(ffi/defcfn raw-close "snd_pcm_close" [:pointer] :int)
(ffi/defcfn raw-set-params "snd_pcm_set_params"
  [:pointer :int :int :uint :uint :int :uint] :int)
(ffi/defcfn raw-readi "snd_pcm_readi" [:pointer :pointer :uint64] :int64)
(ffi/defcfn raw-writei "snd_pcm_writei" [:pointer :pointer :uint64] :int64)
(ffi/defcfn raw-prepare "snd_pcm_prepare" [:pointer] :int)
(ffi/defcfn raw-recover "snd_pcm_recover" [:pointer :int :int] :int)
(ffi/defcfn raw-drain "snd_pcm_drain" [:pointer] :int)
(ffi/defcfn strerror "snd_strerror" [:int] :string)

(defn- check! [rc what]
  (if (neg? rc)
    (throw (ex-info (str "alsa: " what ": " (strerror rc)) {:code rc :op what}))
    rc))

(defn open-pcm
  "Open a PCM by ALSA name — \"default\", \"hw:1,0\", or \"null\" for a device
  that swallows everything and always exists.

  `latency-us` is what ALSA is asked to aim for; it picks buffer and period
  sizes to suit and may not hit it exactly."
  [name stream {:keys [rate channels latency-us]
                :or   {rate 48000 channels 1 latency-us 20000}}]
  (ffi/with-arena [a]
    (let [out (ffi/alloc a 8)
          dir (or (streams stream)
                  (throw (ex-info "unknown pcm stream" {:got stream})))]
      (check! (raw-open out name dir 0) (str "open " name))
      (let [pcm (ffi/read out :pointer)]
        (check! (raw-set-params pcm format-s16-le access-rw-interleaved
                                channels rate 1 latency-us)
                "set_params")
        pcm))))

(defn read!
  "Read up to `frames` frames of interleaved S16 into `buf`.

  Answers {:frames n} on a normal read, or {:frames n :recovered true} when
  an overrun was absorbed. Frames, not bytes — see the namespace docstring."
  [pcm buf frames]
  (let [n (raw-readi pcm buf frames)]
    (if (neg? n)
      (do (check! (raw-recover pcm n 1) "recover")
          (let [n2 (raw-readi pcm buf frames)]
            {:frames (max 0 (check! n2 "readi")) :recovered true}))
      {:frames n})))

(defn write!
  "Write `frames` frames of interleaved S16 from `buf`."
  [pcm buf frames]
  (let [n (raw-writei pcm buf frames)]
    (if (neg? n)
      (do (check! (raw-recover pcm n 1) "recover")
          {:frames (max 0 (check! (raw-writei pcm buf frames) "writei"))
           :recovered true})
      {:frames n})))

(defn prepare! [pcm] (check! (raw-prepare pcm) "prepare") nil)
(defn drain!   [pcm] (check! (raw-drain pcm) "drain") nil)
(defn close!   [pcm] (raw-close pcm) nil)
