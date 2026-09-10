(ns frq.moq.client
  "A MoQ client and the session a connect answers.

  This is the first thing in `frq.moq.*` that does transport rather than
  describe it, and two rules from UniFFI's object model shape all of it.

  **A method consumes a clone of the handle.** UniFFI's generated bindings
  clone before every call and let the callee own that clone — so `call` here
  does the same. Passing the handle itself would hand ownership away and leave
  the next call reading a freed object, which is the kind of bug that surfaces
  minutes later in an allocator rather than at the call that caused it.

  **A connect is a future, not a call.** `connect!` starts one and answers
  immediately; `poll-connect!` is what a caller on the loop thread asks, and
  it answers nil until the far side is ready. That is the same shape
  `frq.av/pump!` already has, and it is deliberate — glimmer runs the loop
  thread, and a blocking connect on it is a frozen window for as long as a
  QUIC handshake takes, or for the full timeout when a relay is unreachable."
  (:require [frq.moq.uniffi :as uniffi]
            [frq.moq.raw :as raw]
            [jolt.ffi :as ffi]))

;; --- handles -----------------------------------------------------------------

(defn- clone-client [h] (uniffi/with-out-status #(raw/clone-moqclient h %)))
(defn- clone-session [h] (uniffi/with-out-status #(raw/clone-moqsession h %)))

(defn free-client!
  "Release a client handle. The sessions it opened outlive it."
  [h]
  (uniffi/with-out-status #(raw/free-moqclient h %))
  nil)

(defn free-session!
  "Release a session handle.

  Not the same as closing the session — `shutdown!` ends the conversation,
  this only drops our reference to it."
  [h]
  (uniffi/with-out-status #(raw/free-moqsession h %))
  nil)

;; --- the client --------------------------------------------------------------

(defn new-client
  "A MoqClient with the object's own defaults: binds `[::]:0`, verifies against
  the system roots."
  []
  (uniffi/with-out-status #(raw/constructor-moqclient-new %)))

(defn set-bind!
  "Set the local UDP bind address, e.g. \"0.0.0.0:0\"."
  [client addr]
  (ffi/with-arena [a]
    (let [buf (ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
      (uniffi/lower-string buf addr)
      (uniffi/with-out-status
        #(raw/method-moqclient-set-bind (clone-client client) buf %))))
  nil)

(defn connect!
  "Begin connecting to `url`; answers a future to poll, not a session.

  The lowered URL is NOT freed here. UniFFI's convention is that a lowered
  argument is handed over with its ownership — the callee frees it — so
  freeing it on this side would be the second free.

  The future is a :u64 one because a MoqSession crosses as a handle, and a
  handle is a u64 whatever it points at."
  [client url]
  (ffi/with-arena [a]
    (let [buf (ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
      (uniffi/lower-string buf url)
      (-> (raw/method-moqclient-connect (clone-client client) buf)
          (uniffi/start-future :u64)))))

(defn poll-connect!
  "Answer the session handle once the connect has settled, or nil while it has
  not. Raises what the far side raised if the connect failed.

  Safe to call from the loop thread as often as a timer fires: when the future
  is not ready this issues another poll and returns, and nothing here blocks."
  [fut]
  (when (uniffi/settled? fut)
    (uniffi/complete! fut)))

;; --- the session -------------------------------------------------------------

(defn shutdown!
  "Graceful shutdown — equivalent to `(cancel! session 0)`.

  Named as upstream names it: UniFFI's Kotlin generator already emits a
  `close()` that releases the FFI handle, so `close` would mean two different
  things depending on which side of the binding you were reading."
  [session]
  (uniffi/with-out-status
    #(raw/method-moqsession-shutdown (clone-session session) %))
  nil)

(defn cancel!
  "Close the session with an error code.

  Code 0 is \"no error\", which is what `shutdown!` sends — upstream documents
  it that way so a caller ending a call normally does not have to invent one."
  ([session] (cancel! session 0))
  ([session code]
   (uniffi/with-out-status
     #(raw/method-moqsession-cancel (clone-session session) code %))
   nil))
