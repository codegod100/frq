(ns frq.crypto.openssl
  "The desktop's answers to `frq.crypto`, over libcrypto.

  The same OpenSSL jolt already loads for TLS — there is no other crypto here
  to borrow, and an Ed25519 written by hand is not a thing to put in a chat
  client. Requiring this installs them.

  The EVP_PKEY lives here rather than in `frq.msgsig`, which is shared and has
  nowhere to put a pointer."
  (:require [frq.crypto :as crypto]
            [jolt.ffi :as ffi]
            [jolt.mvn-http :as tls]))


(ffi/defcfn c-rand-bytes "RAND_bytes" [:pointer :int] :int)
(ffi/defcfn c-new-raw-priv "EVP_PKEY_new_raw_private_key"
  [:int :pointer :pointer :size_t] :pointer)
(ffi/defcfn c-get-raw-pub "EVP_PKEY_get_raw_public_key"
  [:pointer :pointer :pointer] :int)
(ffi/defcfn c-pkey-free "EVP_PKEY_free" [:pointer] :void)
(ffi/defcfn c-md-ctx-new "EVP_MD_CTX_new" [] :pointer)
(ffi/defcfn c-md-ctx-free "EVP_MD_CTX_free" [:pointer] :void)
(ffi/defcfn c-sign-init "EVP_DigestSignInit"
  [:pointer :pointer :pointer :pointer :pointer] :int)
(ffi/defcfn c-sign "EVP_DigestSign" [:pointer :pointer :pointer :pointer :size_t] :int)
(ffi/defcfn c-sha256 "SHA256" [:pointer :size_t :pointer] :pointer)

;; Ed25519's NID, which openssl/obj_mac.h spells EVP_PKEY_ED25519.
(def ^:private nid-ed25519 1087)

(defonce ^:private pkey (atom nil))

(defn- ->bytes
  "Whatever the shared side handed over, as the array ffi/write-array wants.

  `frq.io/utf8-bytes` answers a vector of ints and `frq.msgsig` passes seqs
  around, because those are the only shapes both compilers agree on. The
  conversion belongs here, where the pointer does."
  [bs]
  (if (bytes? bs) bs (byte-array (map unchecked-byte bs))))

(defn- random-bytes [n]
  (tls/ensure-native!)
  (let [buf (ffi/alloc n)]
    (try (when (= 1 (c-rand-bytes buf n)) (ffi/read-array buf n))
         (finally (ffi/free buf)))))

(defn- sha256 [bs]
  (let [bs (->bytes bs)
        n (alength bs)
        in (ffi/alloc (max 1 n))
        out (ffi/alloc 32)]
    (try (ffi/write-array in bs)
         (c-sha256 in n out)
         (ffi/read-array out 32)
         (finally (ffi/free in) (ffi/free out)))))

(defn- forget! []
  (when-let [k @pkey]
    (try (c-pkey-free k) (catch Exception _ nil)))
  (reset! pkey nil))

(defn- generate!
  "The seed IS the key for Ed25519, so `EVP_PKEY_new_raw_private_key` is the
  whole of it. Returns the public half as bytes."
  [seed]
  (forget!)
  (try
    (tls/ensure-native!)
    (let [seed (->bytes seed)
          buf (ffi/alloc 32)]
      (try
        (ffi/write-array buf seed)
        (let [k (c-new-raw-priv nid-ed25519 ffi/null buf 32)]
          (when-not (ffi/null? k)
            (let [pub (ffi/alloc 32)
                  plen (ffi/alloc (ffi/sizeof :size_t))]
              (try
                (ffi/write plen :size_t 32)
                (when (= 1 (c-get-raw-pub k pub plen))
                  (reset! pkey k)
                  (ffi/read-array pub 32))
                (finally (ffi/free pub) (ffi/free plen))))))
        (finally (ffi/free buf))))
    (catch Exception _ nil)))

(defn- sign [bs]
  (when-let [k @pkey]
    (let [bs (->bytes bs)
          n (alength bs)
          msg (ffi/alloc (max 1 n))
          sig (ffi/alloc 64)
          slen (ffi/alloc (ffi/sizeof :size_t))
          ctx (c-md-ctx-new)]
      (try
        (ffi/write-array msg bs)
        (ffi/write slen :size_t 64)
        (when (and (= 1 (c-sign-init ctx ffi/null ffi/null ffi/null k))
                   (= 1 (c-sign ctx sig slen msg n)))
          (ffi/read-array sig (ffi/read slen :size_t)))
        (catch Exception _ nil)
        (finally (ffi/free msg) (ffi/free sig) (ffi/free slen) (c-md-ctx-free ctx))))))

(crypto/install!
 {:random-bytes random-bytes
  :sha256 sha256
  :ed25519-generate! generate!
  :ed25519-sign sign
  :ed25519-forget! forget!})
