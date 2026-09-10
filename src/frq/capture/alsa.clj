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
  (:require [clojure.string :as str]
            [jolt.ffi :as ffi]))

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

;; --- enumeration -------------------------------------------------------------
;; snd_device_name_hint answers a NULL-terminated array of opaque hints, and
;; each field of a hint is a char* the CALLER frees. Both facts shape this:
;; the array is walked a pointer at a time, and every string is read through
;; ptr->string and then released, because declaring it :string would hand
;; back a jolt string and lose the address that has to be freed.

(ffi/defcfn raw-name-hint "snd_device_name_hint" [:int :string :pointer] :int)
(ffi/defcfn raw-get-hint "snd_device_name_get_hint" [:pointer :string] :pointer)
(ffi/defcfn raw-free-hint "snd_device_name_free_hint" [:pointer] :int)

(defn- hint-field [hint id]
  (let [p (raw-get-hint hint id)]
    (when-not (ffi/null? p)
      (let [s (ffi/ptr->string p)]
        (ffi/free p)
        s))))

(defn devices
  "PCMs ALSA is willing to name, as {:id :name :default?}.

  `direction` is :capture or :playback, and it filters on the hint's IOID:
  a device with no IOID does both, which is most of them, so absence means
  yes rather than no.

  The `null` PCM is dropped. It is always present, it swallows everything,
  and a person picking it from a list of microphones would get silence that
  looks exactly like a broken device."
  [direction]
  (let [want (case direction :capture "Input" :playback "Output")]
    (ffi/with-arena [a]
      (let [out (ffi/alloc a 8)]
        (when (neg? (raw-name-hint -1 "pcm" out))
          (throw (ex-info "alsa: could not list devices" {})))
        (let [arr (ffi/read out :pointer)]
          (if (ffi/null? arr)
            []
            (try
              (loop [i 0 acc []]
                (let [hint (ffi/read (+ arr (* 8 i)) :pointer)]
                  (if (ffi/null? hint)
                    acc
                    (let [name (hint-field hint "NAME")
                          desc (hint-field hint "DESC")
                          ioid (hint-field hint "IOID")]
                      (recur (inc i)
                             (if (and name
                                      (not= "null" name)
                                      (or (nil? ioid) (= ioid want)))
                               (conj acc {:id name
                                          ;; DESC is multi-line: a friendly
                                          ;; name, then the card detail.
                                          :name (or (some-> desc str/split-lines first)
                                                    name)
                                          :default? (= "default" name)})
                               acc))))))
              (finally (raw-free-hint arr)))))))))

(defn prepare! [pcm] (check! (raw-prepare pcm) "prepare") nil)
(defn drain!   [pcm] (check! (raw-drain pcm) "drain") nil)
(defn close!   [pcm] (raw-close pcm) nil)
