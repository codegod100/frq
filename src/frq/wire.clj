(ns frq.wire
  "Bytes onto a raw socket, all of them.

  `send(2)` is allowed to accept less than it was given and say so, which is
  not an error and not rare — it is what a full socket buffer looks like. The
  caller has to resume from where it stopped, and the only way to say that to
  the kernel is a pointer further along the buffer: shrinking the length while
  passing the same address re-sends the head of the line and loses the tail.
  The peer then gets the right number of bytes, the wrong ones, and a stream
  that no longer frames.

  Both raw-socket writers in frq had their own version of this loop and both
  had it wrong, so there is one here instead. TLS does not come through — that
  transport is `tls/tls-write`, which handles its own record boundaries."
  (:require [jolt.ffi :as ffi]
            [jolt.socket :as socket]))

(def ^:private no-signal
  "MSG_NOSIGNAL: a write to a closed peer returns EPIPE rather than killing
  the process with SIGPIPE. Read from jolt rather than spelled here, as both
  call sites already did — the value is the platform's, not frq's."
  @#'socket/msg-nosignal)

(defn send-all!
  "Write `text` to `fd` until none is left. Throws if the socket does.

  The byte count is taken as UTF-8 explicitly, because that is what
  `with-c-string` writes: the platform default agrees on every machine frq
  has run on, but a machine where it did not would send a length measured in
  one encoding against bytes laid down in another."
  [fd text]
  (let [len (count (.getBytes ^String text "UTF-8"))]
    (ffi/with-c-string [p text]
      (loop [sent 0]
        (when (< sent len)
          ;; The pointer advances with the length. `p` is an address, so this
          ;; is ordinary arithmetic on it.
          (let [n (socket/c-send fd (+ p sent) (- len sent) no-signal)]
            ;; Anything not positive ends it. Zero especially: recurring on an
            ;; unchanged `sent` is an infinite loop that sends nothing, which
            ;; is worse than the failure it is hiding.
            ;; ponytail: EINTR is thrown rather than retried — jolt.socket
            ;; publishes no errno, so telling it from a real error would mean
            ;; binding __errno_location here. Worth doing if signals ever
            ;; start interrupting these writes in practice.
            (when-not (pos? n)
              (throw (ex-info "send failed" {:fd fd :sent sent :len len :ret n})))
            (recur (+ sent n))))))))
