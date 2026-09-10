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

(def ^:private io-call
  "jolt's own retry wrapper for one blocking-capable socket syscall.

  The `accept`/`recv`/`send` bindings are declared `:capture-native-error`, so
  they answer `[result errno]` rather than a bare number — a pair that reads as
  a socket error nowhere and as `class clojure.lang.PersistentVector cannot be
  cast to class java.lang.Number` the moment a caller asks whether it is
  positive. Taken from jolt rather than unwrapped here, as with `no-signal`
  above: the errno is what tells EINTR and EAGAIN from a real failure, and
  jolt is where that classification lives."
  @#'socket/io-call)

(defn recv!
  "One `recv` into `buf`, answering the byte count — negative or zero at end."
  [fd buf len]
  (io-call #(socket/c-recv fd buf len 0) fd :read))

(defn connect!
  "One `connect` to the address at `sa`, answering zero or a negative.

  `connect` is the fourth of these bindings and was left out of the round
  that fixed the other three: it is only on the plain-socket path, which the
  TLS default does not take, so its pair reached `neg?` unnoticed. The wait
  is for writability — a socket that finishes connecting reports itself
  writable, which is what jolt's poller is being asked about here."
  [fd sa len]
  (io-call #(socket/c-connect fd sa len) fd :write))

(defn accept!
  "One `accept` on a listening fd, answering the connected fd or a negative."
  [fd]
  (io-call #(socket/c-accept fd ffi/null ffi/null) fd :read))

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
          (let [n (io-call #(socket/c-send fd (+ p sent) (- len sent) no-signal)
                           fd :write)]
            ;; Anything not positive ends it. Zero especially: recurring on an
            ;; unchanged `sent` is an infinite loop that sends nothing, which
            ;; is worse than the failure it is hiding.
            ;; EINTR and EAGAIN are already gone by here — io-call retries
            ;; the one and waits out the other — so a non-positive n is the
            ;; socket's final answer.
            (when-not (pos? n)
              (throw (ex-info "send failed" {:fd fd :sent sent :len len :ret n})))
            (recur (+ sent n))))))))
