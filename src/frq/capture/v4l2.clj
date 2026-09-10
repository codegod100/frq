(ns frq.capture.v4l2
  "The camera, behind an ioctl.

  V4L2 is the one part of the media plane that was never going to need a
  library: it is `open`, `ioctl`, `mmap` and a handful of structs, all of it
  in libc and the kernel. What it needs instead is EXACTNESS. Every request
  number below encodes the size of the struct it carries, so a layout that is
  one byte wrong does not read a wrong field — it makes a request number the
  kernel has never heard of, and the driver answers ENOTTY for an ioctl that
  plainly exists.

  That is why `frq.capture.v4l2-test/check-layouts` compares every size and
  offset here against what a C compiler says about the running kernel's
  headers, rather than trusting that they were transcribed correctly.

  A CAPTURED FRAME IS BORROWED. `with-frame` hands the mmap'd buffer straight
  to its callback and requeues it afterwards; the pointer is the driver's, it
  is valid until the buffer goes back, and nothing here copies it. That is
  `frq.av`'s rule arriving from the other end — capture buffer to encoder as a
  pointer, the way the decoder's buffer already reaches a texture."
  (:require [jolt.ffi :as ffi]))

;; --- libc --------------------------------------------------------------------

(ffi/defcfn c-open "open" [:string :int :& :int] :int)
(ffi/defcfn c-close "close" [:int] :int)
;; ioctl's third argument is whatever the request says it is; for every
;; request here it is a pointer, and the declared tail costs no compile.
(ffi/defcfn c-ioctl "ioctl" [:int :uint64 :& :pointer] :int)
(ffi/defcfn c-mmap "mmap" [:pointer :uint64 :int :int :int :int64] :pointer)
(ffi/defcfn c-munmap "munmap" [:pointer :uint64] :int)

(def ^:const o-rdwr 2)
(def ^:const prot-read 1)
(def ^:const prot-write 2)
(def ^:const map-shared 1)

;; --- the requests ------------------------------------------------------------
;; _IOC(dir, type, nr, size) = dir<<30 | size<<16 | 'V'<<8 | nr, with dir 1
;; for write, 2 for read and 3 for both. The size in there is the struct's,
;; which is why the layouts below are checked rather than assumed.

(def ^:const VIDIOC_QUERYCAP  2154321408)
(def ^:const VIDIOC_S_FMT     3234878981)
(def ^:const VIDIOC_REQBUFS   3222558216)
(def ^:const VIDIOC_QUERYBUF  3227014665)
(def ^:const VIDIOC_QBUF      3227014671)
(def ^:const VIDIOC_DQBUF     3227014673)
(def ^:const VIDIOC_STREAMON  1074026002)
(def ^:const VIDIOC_STREAMOFF 1074026003)

(def ^:const buf-type-video-capture 1)
(def ^:const memory-mmap 1)
(def ^:const field-none 1)
(def ^:const cap-video-capture 1)
(def ^:const cap-streaming 67108864)

(def pixel-formats
  "V4L2 fourccs, as the kernel packs them."
  {:yuyv 1448695129 :mjpeg 1196444237 :yuv420 842093913})

;; --- the structs -------------------------------------------------------------
;; Padded to the kernel's sizes rather than described field by field: what
;; matters is the total size (it is in the request number) and the offsets of
;; the fields actually read. A union is spelled as the reserved block it
;; occupies, which is what `v4l2_format` mostly is.

(def capability
  (ffi/layout [:struct [[:driver     [:array :uint8 16]]
                        [:card       [:array :uint8 32]]
                        [:bus-info   [:array :uint8 32]]
                        [:version    :uint32]
                        [:capabilities :uint32]
                        [:device-caps  :uint32]
                        [:reserved   [:array :uint32 3]]]]))

(def format-pix
  ;; v4l2_format is 208 bytes: a type, four bytes of padding, then a union
  ;; whose largest member decides the rest. Only the pix arm is described;
  ;; the tail is the union's remaining bytes.
  (ffi/layout [:struct [[:type         :uint32]
                        [:pad          :uint32]
                        [:width        :uint32]
                        [:height       :uint32]
                        [:pixelformat  :uint32]
                        [:field        :uint32]
                        [:bytesperline :uint32]
                        [:sizeimage    :uint32]
                        [:colorspace   :uint32]
                        [:priv         :uint32]
                        [:flags        :uint32]
                        [:enc          :uint32]
                        [:quantization :uint32]
                        [:xfer-func    :uint32]
                        [:rest         [:array :uint8 152]]]]))

(def requestbuffers
  (ffi/layout [:struct [[:count      :uint32]
                        [:type       :uint32]
                        [:memory     :uint32]
                        [:capabilities :uint32]
                        [:flags      :uint8]
                        [:reserved   [:array :uint8 3]]]]))

(def buffer
  ;; 88 bytes. `timestamp` is a struct timeval at 24, `m` is a union at 64
  ;; whose first member is the mmap offset, and `memory` sits at 60.
  (ffi/layout [:struct [[:index      :uint32]
                        [:type       :uint32]
                        [:bytesused  :uint32]
                        [:flags      :uint32]
                        [:field      :uint32]
                        [:pad0       :uint32]
                        [:tv-sec     :int64]
                        [:tv-usec    :int64]
                        [:timecode   [:array :uint8 16]]
                        [:sequence   :uint32]
                        [:memory     :uint32]
                        [:offset     :uint32]
                        [:pad1       :uint32]
                        [:length     :uint32]
                        [:reserved2  :uint32]
                        [:request-fd :int32]
                        [:pad2       :uint32]]]))

;; --- opening -----------------------------------------------------------------

(defn- ioctl! [fd req p what]
  (let [rc (c-ioctl fd req p)]
    (when (neg? rc)
      (throw (ex-info (str "v4l2: " what " failed") {:errno (ffi/errno) :op what})))
    rc))

(defn open-device
  "Open a camera and answer its fd."
  [path]
  (let [fd (c-open path o-rdwr)]
    (when (neg? fd)
      (throw (ex-info (str "v4l2: cannot open " path) {:errno (ffi/errno) :path path})))
    fd))

(defn capabilities
  "What the device says it can do. `:capture?` and `:streaming?` are the two
  that decide whether the rest of this namespace applies to it."
  [fd]
  (ffi/with-arena [a]
    (let [p (ffi/alloc a (ffi/layout-size capability))]
      (ioctl! fd VIDIOC_QUERYCAP p "QUERYCAP")
      (let [caps (ffi/read-field p capability [:capabilities])
            dev  (ffi/read-field p capability [:device-caps])
            ;; device_caps describes THIS node; capabilities describes the
            ;; whole device, which on a multi-node camera is not the same
            ;; thing and is the usual reason a /dev/video1 refuses to stream.
            eff  (if (zero? dev) caps dev)]
        {:capabilities caps
         :device-caps dev
         :capture?   (pos? (bit-and eff cap-video-capture))
         :streaming? (pos? (bit-and eff cap-streaming))}))))

(defn set-format!
  "Ask for a size and pixel format; answers what the driver actually chose.

  V4L2 negotiates rather than obeys — a driver may answer a different size or
  a different format entirely, and the returned map is the truth."
  [fd width height pixel-format]
  (ffi/with-arena [a]
    (let [p (ffi/alloc a (ffi/layout-size format-pix))
          fourcc (or (pixel-formats pixel-format) pixel-format)]
      (ffi/write p format-pix {:type buf-type-video-capture :pad 0
                               :width width :height height
                               :pixelformat fourcc :field field-none
                               :bytesperline 0 :sizeimage 0 :colorspace 0
                               :priv 0 :flags 0 :enc 0 :quantization 0
                               :xfer-func 0 :rest (vec (repeat 152 0))})
      (ioctl! fd VIDIOC_S_FMT p "S_FMT")
      {:width        (ffi/read-field p format-pix [:width])
       :height       (ffi/read-field p format-pix [:height])
       :pixelformat  (ffi/read-field p format-pix [:pixelformat])
       :bytesperline (ffi/read-field p format-pix [:bytesperline])
       :sizeimage    (ffi/read-field p format-pix [:sizeimage])})))

;; --- buffers -----------------------------------------------------------------

(defn request-buffers!
  "Ask the driver for `n` mmap buffers; answers how many it granted."
  [fd n]
  (ffi/with-arena [a]
    (let [p (ffi/alloc a (ffi/layout-size requestbuffers))]
      (ffi/write p requestbuffers {:count n :type buf-type-video-capture
                                   :memory memory-mmap :capabilities 0
                                   :flags 0 :reserved [0 0 0]})
      (ioctl! fd VIDIOC_REQBUFS p "REQBUFS")
      (ffi/read-field p requestbuffers [:count]))))

(defn- blank-buffer [p index]
  (ffi/write p buffer {:index index :type buf-type-video-capture :bytesused 0
                       :flags 0 :field 0 :pad0 0 :tv-sec 0 :tv-usec 0
                       :timecode (vec (repeat 16 0)) :sequence 0
                       :memory memory-mmap :offset 0 :pad1 0 :length 0
                       :reserved2 0 :request-fd 0 :pad2 0}))

(defn map-buffers!
  "QUERYBUF then mmap each buffer; answers a vector of {:ptr :len :index}."
  [fd n]
  (ffi/with-arena [a]
    (let [p (ffi/alloc a (ffi/layout-size buffer))]
      (mapv (fn [i]
              (blank-buffer p i)
              (ioctl! fd VIDIOC_QUERYBUF p "QUERYBUF")
              (let [len (ffi/read-field p buffer [:length])
                    off (ffi/read-field p buffer [:offset])
                    ptr (c-mmap ffi/null len (bit-or prot-read prot-write)
                                map-shared fd off)]
                (when (= ptr -1)
                  (throw (ex-info "v4l2: mmap failed" {:errno (ffi/errno) :index i})))
                {:index i :ptr ptr :len len}))
            (range n)))))

(defn queue!
  "Hand a buffer back to the driver."
  [fd index]
  (ffi/with-arena [a]
    (let [p (ffi/alloc a (ffi/layout-size buffer))]
      (blank-buffer p index)
      (ioctl! fd VIDIOC_QBUF p "QBUF")))
  nil)

(defn stream-on!  [fd]
  (ffi/with-arena [a]
    (let [t (ffi/alloc a 4)]
      (ffi/write t :uint32 buf-type-video-capture)
      (ioctl! fd VIDIOC_STREAMON t "STREAMON")))
  nil)

(defn stream-off! [fd]
  (ffi/with-arena [a]
    (let [t (ffi/alloc a 4)]
      (ffi/write t :uint32 buf-type-video-capture)
      (ioctl! fd VIDIOC_STREAMOFF t "STREAMOFF")))
  nil)

(defn with-frame
  "Dequeue a frame, hand it to `f` as [pointer length], and requeue it.

  The pointer is the driver's mmap'd buffer, valid only until the requeue —
  which is why the buffer goes back in a `finally` and why `f` is called
  rather than the span being answered. Copying it here would be the one copy
  frq.av exists to avoid."
  [fd buffers f]
  (ffi/with-arena [a]
    (let [p (ffi/alloc a (ffi/layout-size buffer))]
      (blank-buffer p 0)
      (ioctl! fd VIDIOC_DQBUF p "DQBUF")
      (let [i   (ffi/read-field p buffer [:index])
            n   (ffi/read-field p buffer [:bytesused])
            buf (nth buffers i)]
        (try
          (f (:ptr buf) n)
          (finally (queue! fd i)))))))

(defn close-device! [fd buffers]
  (doseq [{:keys [ptr len]} buffers] (c-munmap ptr len))
  (c-close fd)
  nil)
