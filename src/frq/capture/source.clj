(ns frq.capture.source
  "Real devices as the thunks `frq.av.plane` takes.

  The plane asks for `:source` and `:mic` — functions answering [pointer
  length] or nil — and does not know or care where the pixels came from.
  This namespace is where a camera and a microphone become those functions,
  and keeping it separate is what lets the plane be tested with a synthetic
  frame and run with a real one without a line of it changing.

  Both are NON-BLOCKING, because the plane is pumped from glimmer's loop
  thread. A blocking read here would hold the whole UI for as long as the
  device felt like taking, and on a device that has stopped producing, for
  ever. Nothing ready is a nil, not a wait."
  (:require [frq.capture.alsa :as alsa]
            [frq.capture.v4l2 :as v4l2]
            [frq.av.audio :as audio]
            [jolt.ffi :as ffi]))

(ffi/defcfn yuyv->i420 "frq_yuyv_to_i420" [:pointer :pointer :int :int] :void)

;; --- the camera --------------------------------------------------------------

(defn camera
  "Open `path` and answer {:source :close! :width :height}.

  YUYV is asked for because every UVC camera has it and openh264 wants I420,
  which is one pass away. MJPEG would be smaller on the wire between camera
  and kernel but needs a JPEG decoder in front of the converter, and this
  path already has enough moving parts.

  V4L2 NEGOTIATES: the size that comes back is not necessarily the size
  asked for, so the answer carries what the driver actually chose and the
  encoder should be opened from that rather than from the request."
  [path {:keys [width height buffers] :or {width 640 height 480 buffers 4}}]
  (let [fd   (v4l2/open-device path)
        caps (v4l2/capabilities fd)]
    (when-not (:capture? caps)
      (v4l2/close-device! fd [])
      (throw (ex-info "v4l2: not a capture device" {:path path :caps caps})))
    (let [fmt (v4l2/set-format! fd width height :yuyv)
          w   (:width fmt) h (:height fmt)
          n   (v4l2/request-buffers! fd buffers)
          bufs (v4l2/map-buffers! fd n)
          ;; One I420 frame, allocated once. The converter writes here and
          ;; the encoder reads here; a fresh allocation per frame would put
          ;; the allocator in the capture path.
          i420 (ffi/alloc (+ (* w h) (* 2 (quot (* w h) 4))))]
      (doseq [{:keys [index]} bufs] (v4l2/queue! fd index))
      (v4l2/stream-on! fd)
      {:width  w
       :height h
       :source (fn []
                 (v4l2/try-frame
                   fd bufs
                   (fn [ptr _len]
                     (yuyv->i420 ptr i420 w h)
                     [i420 (+ (* w h) (* 2 (quot (* w h) 4)))])))
       :close! (fn []
                 (try (v4l2/stream-off! fd) (catch Exception _ nil))
                 (v4l2/close-device! fd bufs)
                 (ffi/free i420))})))

;; --- the microphone ----------------------------------------------------------

(defn microphone
  "Open an ALSA capture PCM and answer {:mic :close!}.

  One Opus frame at a time — 20ms, `audio/frame-samples` per channel —
  because that is the unit the encoder takes and the jitter buffer holds.
  Reading a different amount would mean carrying a remainder between pumps,
  which is a buffer this does not need to own.

  A short read answers nil rather than a partial frame. Opus encodes whole
  frames, and padding a short one with silence puts a click in the audio
  every time the device is a little behind."
  [name {:keys [channels] :or {channels 1}}]
  (let [pcm (alsa/open-pcm name :capture
                           {:rate audio/sample-rate :channels channels
                            :latency-us 40000})
        buf (ffi/alloc (* 2 audio/frame-samples channels))]
    (alsa/prepare! pcm)
    {:mic (fn []
            (let [{:keys [frames]} (alsa/read! pcm buf audio/frame-samples)]
              (when (= frames audio/frame-samples)
                [buf frames])))
     :close! (fn [] (alsa/close! pcm) (ffi/free buf))}))

;; --- the speaker -------------------------------------------------------------

(defn speaker
  "Open an ALSA playback PCM and answer {:play! :close!}.

  `play!` takes what `frq.av.plane/poll-audio!` answers and writes it. It is
  the one place in this port where a short write is silently fine: ALSA
  accepting fewer frames than offered means the device's buffer is full,
  which for playback means we are ahead rather than behind."
  [name {:keys [channels] :or {channels 1}}]
  (let [pcm (alsa/open-pcm name :playback
                           {:rate audio/sample-rate :channels channels
                            :latency-us 40000})]
    {:play!  (fn [{:keys [ptr samples]}]
               (when ptr (alsa/write! pcm ptr samples)))
     :close! (fn [] (alsa/close! pcm))}))
