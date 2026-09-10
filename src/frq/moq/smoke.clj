(ns frq.moq.smoke
  "The smallest round trip that proves the generated bindings are real.

  Nothing in `frq.moq.*` has crossed the ABI until something does, and the
  failure modes here are not the kind that announce themselves: a RustBuffer
  whose fields are the wrong width reads as plausible garbage, and a handle
  freed twice corrupts an allocator some minutes later rather than at the call.
  So this checks, in order, the three things everything else assumes —

    1. the contract version, which is the object saying it is the one the
       bindings were generated from;
    2. a handle's whole life — construct a MoqClient, then free it — which is
       the RustCallStatus out-parameter working in both directions;
    3. a string out and back, which is the RustBuffer layout and the
       alloc/free ownership rule.

  It deliberately does NOT connect. A connect is a future, a tokio worker and
  a network, and none of those tell you anything if the layouts are wrong.

      just repl -m frq.moq.smoke"
  (:require [frq.moq.uniffi :as uniffi]
            [frq.moq.raw :as raw]
            [jolt.ffi :as ffi]))

(defn- check-contract []
  (let [v (uniffi/check-abi!)]
    (println "  contract version:" v "(expected" uniffi/expected-contract ")")
    true))

(defn- check-handle
  "Construct and free a MoqClient.

  `moqclient_new` is the one constructor that takes nothing but a status, so
  it isolates the status protocol from any argument lowering. The free is not
  a courtesy: it is the other half of the handle contract, and a binding that
  cannot free is a binding that leaks a QUIC endpoint per call."
  []
  (let [h (uniffi/with-out-status #(raw/constructor-moqclient-new %))]
    (println "  moqclient_new ->" h)
    (when (zero? h)
      (throw (ex-info "moqclient_new answered a null handle" {})))
    (uniffi/with-out-status #(raw/free-moqclient h %))
    (println "  free_moqclient ok")
    true))

(defn- check-string
  "Send a string into a RustBuffer and read it back out.

  The value is chosen to catch the two mistakes a length-counted buffer
  invites: multi-byte UTF-8 (a length in characters rather than bytes reads
  short) and a trailing character (a NUL-terminated read runs past the end)."
  []
  (let [s "moq://relay.example/ünïcode/✓"]
    (ffi/with-arena [a]
      (let [buf (ffi/alloc a (ffi/layout-size uniffi/rust-buffer))]
        (uniffi/lower-string buf s)
        (let [len (ffi/read-field buf uniffi/rust-buffer [:len])
              got (uniffi/lift-string buf)]
          (println "  lowered" (count s) "chars ->" len "bytes in the buffer")
          (println "  lifted  " (pr-str got))
          (when-not (= s got)
            (throw (ex-info "string did not round trip"
                            {:sent s :got got})))
          true)))))

(defn -main [& _]
  (println "libmoq_ffi smoke test")
  (let [steps [["contract" check-contract]
               ["handle"   check-handle]
               ["string"   check-string]]]
    (doseq [[name f] steps]
      (println (str name ":"))
      (f))
    (println "all ok")))
