(ns frq.codec.h264
  "H.264 encoding, through openh264.

  Not through openh264 DIRECTLY, and the reason is a calling convention.
  openh264's C API is not flat: `ISVCEncoder` is `const ISVCEncoderVtbl*`, so
  every method — Initialize, EncodeFrame, Uninitialize — is a function pointer
  read out of a table hanging off the object. jolt.ffi cannot call one. Chez
  fixes a foreign procedure's argument and result types when it COMPILES it,
  which is also why the target has to be a literal C symbol name rather than
  an address; `jolt/ffi.clj` says so in as many words.

  So `c/frq_h264.c` walks the vtable and exports five plain symbols, and this
  namespace binds those. The shim is a hundred lines that change a calling
  convention; it holds no policy and makes no decisions that belong here.

  It does flatten the output, because that part cannot sensibly live in jolt:
  openh264 answers an `SFrameBSInfo` of layers, each with its own NAL count
  over a shared buffer, and walking that from here would mean reading nested
  C structs whose layout is openh264's business rather than ours.

  A FRAME IS BORROWED, both ways. `encode!` takes a pointer to I420 and
  answers a span into the encoder's own buffer, valid until the next call on
  the same encoder. That is `frq.av`'s existing contract for video — decoder
  buffer to texture as a pointer, never copied on this side — and it is why
  nothing here turns a picture into a jolt value."
  (:require [jolt.ffi :as ffi]))

(ffi/defcfn raw-open "frq_h264_open" [:int :int :int :int :pointer] :int)
(ffi/defcfn raw-encode "frq_h264_encode"
  [:pointer :pointer :int64 :pointer :pointer :pointer] :int)
(ffi/defcfn raw-force-keyframe "frq_h264_force_keyframe" [:pointer] :int)
(ffi/defcfn raw-close "frq_h264_close" [:pointer] :void)

(defn i420-size
  "Bytes in one I420 frame: a luma plane, then two at quarter resolution."
  [width height]
  (+ (* width height) (* 2 (quot (* width height) 4))))

(defn encoder
  "Open an encoder. `bitrate` is bits per second.

  openh264 validates here rather than at the first frame, so an impossible
  size or bitrate raises now."
  [{:keys [width height fps bitrate] :or {fps 30 bitrate 1000000}}]
  (ffi/with-arena [a]
    (let [out (ffi/alloc a 8)
          rc  (raw-open width height fps bitrate out)]
      (when-not (zero? rc)
        (throw (ex-info "openh264: could not open an encoder"
                        {:code rc :width width :height height
                         :fps fps :bitrate bitrate})))
      (let [h (ffi/read out :pointer)]
        (when (ffi/null? h)
          (throw (ex-info "openh264: encoder handle is NULL" {})))
        h))))

(defn encode!
  "Encode one I420 frame and hand the result to `use-frame`.

  `i420` is a pointer to `(i420-size w h)` bytes. `use-frame` is called with
  [pointer length keyframe?] and its value is answered; the span is the
  encoder's own buffer and is valid only for the duration of that call.

  A frame openh264 chose to skip calls `use-frame` with a zero length rather
  than raising — a skip is a decision, not a failure."
  [enc i420 pts-us use-frame]
  (ffi/with-arena [a]
    (let [out (ffi/alloc a 8)
          len (ffi/alloc a 4)
          key (ffi/alloc a 4)
          rc  (raw-encode enc i420 pts-us out len key)]
      (when-not (zero? rc)
        (throw (ex-info "openh264: encode failed" {:code rc})))
      (use-frame (ffi/read out :pointer)
                 (ffi/read len :int32)
                 (not (zero? (ffi/read key :int32)))))))

(defn force-keyframe!
  "Make the next frame an IDR — what a newly arrived subscriber needs."
  [enc]
  (raw-force-keyframe enc)
  nil)

(defn close! [enc] (raw-close enc) nil)
