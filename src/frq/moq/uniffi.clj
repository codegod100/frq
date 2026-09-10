(ns frq.moq.uniffi
  "The UniFFI ABI, in jolt — the substrate every `frq.moq.*` binding sits on.

  `libmoq_ffi` is not a hand-written C library. It is what UniFFI generates,
  and its shape is the same one UniFFI's Swift and Kotlin backends consume:

  * **Values cross as `RustBuffer`** — a {capacity, len, data} triple, passed
    and returned BY VALUE. A string is its UTF-8 bytes in one; so is a lowered
    error. The buffer is Rust-owned and must go back through `rustbuffer_free`.
  * **Errors are an out-parameter.** Every fallible entry point takes a
    trailing `RustCallStatus *`, and the `code` byte in it says what happened:
    0 succeeded, 1 threw (the lowered error is in `errorBuf`), 2 panicked (a
    message is in `errorBuf`).
  * **Objects are handles**, not pointers — a `uint64_t` with `clone_*` and
    `free_*` around it. A handle is cloned before each method call and freed
    once, which is what UniFFI's generated code does and why doing it by hand
    is the part to get right.
  * **Async is a future to be polled.** `connect` and friends return a future
    handle rather than a value: poll it with a continuation callback, and when
    the callback reports READY, `complete` it for the result and `free` it.

  Two facts about the far side shape the async half here. The continuation is
  invoked from a tokio worker — a thread jolt did not start — so it is built in
  an `auto-arena` and marked `:collect-safe`, which is exactly the case that
  arena documents. And `frq.av`'s contract is that nothing calls back into the
  UI: the continuation therefore does the smallest possible thing, flipping a
  flag, and `settled?` is what a caller on the loop thread asks.

  The version guard is not optional. UniFFI writes a contract version and a
  per-method checksum into the object, and a `libmoq_ffi` built from a
  different revision will have the same symbol names with different layouts
  behind them. `check-abi!` is called once at load; a mismatch is a hard error
  rather than a corrupted read some minutes into a call."
  (:require [jolt.ffi :as ffi]
            [frq.moq.raw :as raw]))

;; --- the primitives ----------------------------------------------------------
;; UNIFFI_SHARED_HEADER_V4. These three are stable across uniffied crates —
;; the header carries a guard that refuses to mix versions, and these layouts
;; are that version's.

(def rust-buffer
  (ffi/layout [:struct [[:capacity :uint64]
                        [:len      :uint64]
                        [:data     :pointer]]]))

(def foreign-bytes
  (ffi/layout [:struct [[:len  :int32]
                        [:data :pointer]]]))

(def rust-call-status
  (ffi/layout [:struct [[:code      :int8]
                        [:error-buf [:struct [[:capacity :uint64]
                                              [:len      :uint64]
                                              [:data     :pointer]]]]]]))

;; `code` in a RustCallStatus.
(def ^:const status-ok     0)
(def ^:const status-error  1)
(def ^:const status-panic  2)

;; What a continuation is handed. READY means `complete` will not block;
;; MAYBE-READY means poll again.
(def ^:const poll-ready       0)
(def ^:const poll-maybe-ready 1)

;; --- the entry points -------------------------------------------------------
;; Not redeclared here. `frq.moq.raw` is generated from the object's own
;; embedded metadata and already declares all 403 of them, including these —
;; so this namespace binds behaviour to them rather than restating signatures
;; that a regeneration could move underneath it.

;; --- errors ------------------------------------------------------------------

;; Forward: `with-out-status` expands to a call to this, and jolt resolves the
;; expansion when it ANALYSES it rather than when it runs.
(declare throw-status!)

(defmacro with-out-status
  "Run `f` with a zeroed RustCallStatus, then raise if it came back non-ok.

  Every fallible entry point in the object takes one of these as its last
  argument, so this is the shape nearly every call in `frq.moq.*` wears. The
  status is confined: it lives exactly as long as the call."
  [f]
  `(ffi/with-arena [a#]
     (let [s# (ffi/alloc a# (ffi/layout-size rust-call-status))]
       (ffi/write s# rust-call-status {:code status-ok
                                       :error-buf {:capacity 0 :len 0
                                                   :data ffi/null}})
       (let [v# (~f s#)]
         (if (= status-ok (ffi/read-field s# rust-call-status [:code]))
           v#
           (throw-status! s#))))))

(defn- status-message
  "Read and RELEASE the lowered error sitting in a non-ok status.

  Both `error` and `panic` put a RustBuffer in `errorBuf`, and both are the
  caller's to free — the difference is only what is inside. A panic's buffer is
  a bare UTF-8 message; an error's is the lowered `MoqError`, whose first bytes
  are a variant discriminant. Neither is decoded here: this namespace does not
  know MoqError's shape, so it reports the bytes it can and leaves lifting the
  variant to the binding that declared the type.

  The free goes through a status of its own rather than `with-out-status`: this
  is already the error path, and a raise from freeing an error buffer would
  lose the error that got us here."
  [status-ptr]
  (let [len  (ffi/read-field status-ptr rust-call-status [:error-buf :len])
        data (ffi/read-field status-ptr rust-call-status [:error-buf :data])
        text (when (and (pos? len) (not (ffi/null? data)))
               ;; Not ptr->string: the buffer is length-counted, not
               ;; NUL-terminated, and a lowered error may hold an interior zero.
               (ffi/read-bytes data len))]
    (ffi/with-arena [a]
      (let [free-status (ffi/alloc a (ffi/layout-size rust-call-status))]
        (ffi/write free-status rust-call-status
                   {:code status-ok
                    :error-buf {:capacity 0 :len 0 :data ffi/null}})
        (raw/rustbuffer-free (ffi/place status-ptr rust-call-status [:error-buf])
                             free-status)))
    text))

(defn- throw-status! [status-ptr]
  (let [code (ffi/read-field status-ptr rust-call-status [:code])
        msg  (status-message status-ptr)]
    (throw (ex-info (if (= code status-panic)
                      (str "libmoq_ffi panicked: " msg)
                      (str "libmoq_ffi call failed: " msg))
                    {:code code :message msg}))))

;; --- strings -----------------------------------------------------------------

(defn lower-string
  "Copy `s` into a Rust-owned RustBuffer, written into `dest`.

  UniFFI lowers a bare String as its UTF-8 bytes with no length prefix — the
  buffer's own `len` is the length. `from_bytes` copies, so the ForeignBytes
  jolt hands over may live in a confined arena and die with this call.

  The bytes come from `string->ptr`, which encodes UTF-8 and records the size
  it allocated; that size counts the NUL it appends, which is why the length
  handed to Rust is one less. A NUL is not part of the value here — a
  RustBuffer is length-counted, and including the terminator would append a
  zero byte to every string that crossed."
  [dest s]
  (ffi/with-arena [a]
    (let [p   (ffi/string->ptr a s)
          n   (max 0 (dec (ffi/size p)))
          fbs (ffi/alloc a (ffi/layout-size foreign-bytes))]
      (ffi/write fbs foreign-bytes {:len n :data p})
      (with-out-status #(raw/rustbuffer-from-bytes dest fbs %))
      dest)))

(defn lift-string
  "Read a returned RustBuffer as a string and free it.

  `read-bytes` decodes UTF-8 itself, so the length-counted bytes become a jolt
  string in one block move — no NUL is looked for, which is what a buffer that
  may hold an interior zero needs.

  The buffer is Rust-owned, so it goes back through `rustbuffer_free` whether
  or not it held anything: a zero-length buffer still carries a capacity."
  [rb-ptr]
  (let [len  (ffi/read-field rb-ptr rust-buffer [:len])
        data (ffi/read-field rb-ptr rust-buffer [:data])
        s    (if (and (pos? len) (not (ffi/null? data)))
               (ffi/read-bytes data len)
               "")]
    (with-out-status #(raw/rustbuffer-free rb-ptr %))
    s))

;; --- futures -----------------------------------------------------------------

(defn- continuation
  "A `void (uint64_t data, int8_t poll_result)` for the far side to invoke.

  Built in the auto-arena and `:collect-safe` on purpose: tokio calls this from
  a worker thread jolt never started, and no lexical scope on this side is the
  callback's lifetime — which is the case `ffi/auto-arena` exists for.

  It does as little as a callback can. Recording the poll result into an atom
  is the whole body; nothing here touches glimmer, allocates a jolt value that
  outlives the call, or re-enters the object. `frq.av`'s rule that nothing
  calls back into the UI survives because the UI is never on this path — a
  caller on the loop thread reads the atom instead."
  [state]
  (ffi/callback (ffi/auto-arena)
                (fn [_data result] (reset! state (long result)))
                [:uint64 :int8] :void
                :collect-safe))

(defn start-future
  "Begin polling `handle`, and answer a map the loop thread can interrogate.

  `kind` picks the width family — :u64 for an object or integer result, :void
  for one that resolves to nothing, :rb for a value that arrives as a buffer.
  The future is NOT awaited here: `settled?` says whether it is ready and
  `complete!` takes the result, so a caller drives this from the same timer
  that drives `frq.av/pump!` rather than blocking the loop."
  [handle kind]
  (let [state (atom nil)
        cb    (continuation state)
        poll  (case kind
                :u64  raw/rust-future-poll-u64
                :void raw/rust-future-poll-void
                :rb   raw/rust-future-poll-rust-buffer)]
    (poll handle cb 0)
    {:handle handle :kind kind :state state :callback cb :poll poll}))

(defn settled?
  "Has the continuation reported READY?

  MAYBE-READY means the far side wants another poll, which this issues and
  then answers false — so calling `settled?` from a timer is what advances a
  future, and there is no thread on this side waiting on one."
  [{:keys [handle state poll callback]}]
  (let [r @state]
    (cond
      (nil? r)                 false
      (= r poll-ready)         true
      (= r poll-maybe-ready)   (do (reset! state nil)
                                   (poll handle callback 0)
                                   false)
      :else                    false)))

(defn complete!
  "Take a settled future's result and release it.

  Only valid once `settled?` has answered true — completing early is what
  blocks the calling thread, which on the loop thread is the freeze this whole
  polling shape exists to avoid. The future handle is freed either way, so a
  raising `complete` still does not leak one."
  [{:keys [handle kind]}]
  (try
    (case kind
      :u64  (with-out-status #(raw/rust-future-complete-u64 handle %))
      :void (do (with-out-status #(raw/rust-future-complete-void handle %)) nil)
      :rb   (ffi/with-arena [a]
              (let [out (ffi/alloc a (ffi/layout-size rust-buffer))]
                (with-out-status #(raw/rust-future-complete-rust-buffer out handle %))
                out)))
    (finally
      (case kind
        :u64  (raw/rust-future-free-u64 handle)
        :void (raw/rust-future-free-void handle)
        :rb   (raw/rust-future-free-rust-buffer handle)))))

;; --- the version guard -------------------------------------------------------

;; What this file was written against: moq-ffi 0.3.17, UniFFI contract 30.
;; Both are asserted rather than assumed — see the namespace docstring on why a
;; silent mismatch is the failure mode worth spending a startup check on.
(def ^:const expected-contract 30)

(defn check-abi!
  "Refuse a `libmoq_ffi` this file was not written against."
  []
  (let [v (raw/uniffi-contract-version)]
    (when-not (= v expected-contract)
      (throw (ex-info (str "libmoq_ffi UniFFI contract " v
                           ", expected " expected-contract
                           " — frq.moq.* was generated against moq-ffi 0.3.17")
                      {:found v :expected expected-contract})))
    v))
