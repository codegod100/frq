(ns frq.msgsig
  "Ed25519 signatures for the mutations freeq will not take on trust.

  A reaction is not a message: it changes something already said, and the
  server refuses an unsigned one from an account —
  `FAIL TAGMSG SIGNATURE_REQUIRED`. Guests are exempt, which is why a react
  looks fine from a guest connection and vanishes from every other client the
  moment you sign in.

  So a signed-in connection mints a throwaway Ed25519 key, registers the public
  half with `MSGSIG` once it is welcomed, and signs each mutation over a
  canonical description of what it does: who, what kind, which message, where,
  and with which emoji. The key lives as long as the connection and is never
  written down — it says only \"the account on this session did this\", which
  is all the server is asking.

  The primitives are OpenSSL's, reached through the same libcrypto jolt already
  loads for TLS. There is no other crypto here to borrow, and an Ed25519
  written by hand is not a thing to put in a chat client."
  (:require [clojure.string :as str]
            [jolt.ffi :as ffi]
            [jolt.host :as host]
            [jolt.mvn-http :as tls]))

;; ---------------------------------------------------------------- libcrypto

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

;; EVP_PKEY_ED25519. The one NID this namespace needs, and the one number in
;; OpenSSL's table that would be a silent wrong key if it were wrong.
(def ^:private nid-ed25519 1087)

;; ---------------------------------------------------------------- encoding

(def ^:private b64url-alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

(defn- b64url
  "base64url of raw bytes, unpadded — how freeq writes a key and a signature.

  `frq.atproto/b64-encode` is the same encoding over a *string*, and a
  signature is not one: run through a String it would come back re-encoded and
  no longer verify."
  [bs]
  (let [bs (mapv #(bit-and (int %) 0xff) bs)]
    (apply str
           (for [group (partition-all 3 bs)
                 :let [[a b c] group
                       n (count group)
                       v (+ (bit-shift-left a 16)
                            (bit-shift-left (or b 0) 8)
                            (or c 0))]
                 i (range (inc n))]
             (nth b64url-alphabet
                  (bit-and (bit-shift-right v (* 6 (- 3 i))) 0x3f))))))

(defn- random-bytes
  "`n` bytes from OpenSSL's CSPRNG, or nil if it will not give them."
  [n]
  (let [buf (ffi/alloc n)]
    (try (when (= 1 (c-rand-bytes buf n)) (ffi/read-array buf n))
         (finally (ffi/free buf)))))

(defn- sha256 [bs]
  (let [n (alength bs)
        in (ffi/alloc (max 1 n))
        out (ffi/alloc 32)]
    (try (ffi/write-array in bs)
         (c-sha256 in n out)
         (ffi/read-array out 32)
         (finally (ffi/free in) (ffi/free out)))))

;; ---------------------------------------------------------------- the key

;; One key per connection: {:pkey <EVP_PKEY*> :public <b64url> :kid <b64url>
;; :did <did>}. Held here rather than on the connection because a signature is
;; not something the transport should be able to hand out.
(defonce ^:private signer (atom nil))

(defn forget!
  "Drop the session key. Called when the connection goes, so a reconnect signs
  with a key the server has actually been told about."
  []
  (when-let [{:keys [pkey]} @signer]
    (try (c-pkey-free pkey) (catch Exception _ nil)))
  (reset! signer nil))

(defn public-key
  "This connection's public key as base64url, or nil before there is one."
  []
  (:public @signer))

(defn generate!
  "Mint this connection's signing key for `did`, and return the public half as
  base64url — the argument `MSGSIG` takes. nil if libcrypto will not play, and
  then nothing is signed and reactions stay a thing only this client sees.

  The private key is a random 32-byte seed rather than a keygen context: for
  Ed25519 the seed *is* the key, and `EVP_PKEY_new_raw_private_key` is the
  whole of it."
  [did]
  (forget!)
  (try
    (tls/ensure-native!)
    (when-let [seed (random-bytes 32)]
      (let [buf (ffi/alloc 32)]
        (try
          (ffi/write-array buf seed)
          (let [pkey (c-new-raw-priv nid-ed25519 ffi/null buf 32)]
            (when-not (ffi/null? pkey)
              (let [pub (ffi/alloc 32)
                    plen (ffi/alloc (ffi/sizeof :size_t))]
                (try
                  (ffi/write plen :size_t 32)
                  (when (= 1 (c-get-raw-pub pkey pub plen))
                    (let [raw (ffi/read-array pub 32)]
                      (reset! signer
                              {:pkey pkey
                               :did did
                               :public (b64url raw)
                               ;; The key id freeq names a signature by: the
                               ;; first half of the key's own SHA-256.
                               :kid (b64url (take 16 (sha256 raw)))})
                      (:public @signer)))
                  (finally (ffi/free pub) (ffi/free plen))))))
          (finally (ffi/free buf)))))
    (catch Exception _ nil)))

(defn- sign-bytes
  "An Ed25519 signature over `bs`, as `ed25519:<kid>:<b64url>` — the shape
  freeq's `+freeq.at/sig` carries."
  [bs]
  (when-let [{:keys [pkey kid]} @signer]
    (let [n (alength bs)
          msg (ffi/alloc (max 1 n))
          sig (ffi/alloc 64)
          slen (ffi/alloc (ffi/sizeof :size_t))
          ctx (c-md-ctx-new)]
      (try
        (ffi/write-array msg bs)
        (ffi/write slen :size_t 64)
        (when (and (= 1 (c-sign-init ctx ffi/null ffi/null ffi/null pkey))
                   (= 1 (c-sign ctx sig slen msg n)))
          (str "ed25519:" kid ":" (b64url (ffi/read-array sig (ffi/read slen :size_t)))))
        (catch Exception _ nil)
        (finally (ffi/free msg) (ffi/free sig) (ffi/free slen) (c-md-ctx-free ctx))))))

;; ---------------------------------------------------------------- canonical

(defn- json-string [s]
  (str "\"" (-> (or s "")
                (str/replace "\\" "\\\\")
                (str/replace "\"" "\\\""))
       "\""))

(defn- canonical
  "The bytes that get signed: a JSON object with its keys in sorted order and
  no space in it. Both ends build this string from the same fields and neither
  sends it — a signature over anything else is a signature over nothing."
  [m]
  (.getBytes (str "{"
                  (str/join "," (for [[k v] (into (sorted-map) m)]
                                  (str (json-string k) ":" (json-string v))))
                  "}")
             "UTF-8"))

(def ^:private crockford "0123456789ABCDEFGHJKMNPQRSTVWXYZ")

(defn- event-id
  "A fresh id for this mutation: ten characters of the clock, then sixteen of
  chance. Sortable like the msgids the server hands out, and unguessable
  enough that two clients cannot mint the same one."
  []
  (let [t (loop [t (quot (host/wall-nanos) 1000000) out ""]
            (if (>= (count out) 10)
              out
              (recur (quot t 32) (str (nth crockford (mod t 32)) out))))]
    (apply str t (for [b (or (random-bytes 16) (repeat 16 0))]
                   (nth crockford (mod (bit-and (int b) 0xff) 32))))))

(defn signing-target
  "How freeq names the place a mutation happens: a channel by its lowercased
  name, a DM by both DIDs in sorted order. nil when there is no way to say it
  — a DM with someone whose DID we have not seen yet — and an unsigned
  mutation is better than one signed over the wrong thing."
  [target our-did peer-did]
  (cond
    (or (str/starts-with? (or target "") "#")
        (str/starts-with? (or target "") "&")) (str/lower-case target)
    (and (seq our-did) (seq peer-did)) (if (<= (compare our-did peer-did) 0)
                                         (str "dm:" our-did "," peer-did)
                                         (str "dm:" peer-did "," our-did))
    :else nil))

(def ^:private hex-digits "0123456789abcdef")

(defn- body-hash
  "How a document names the text it covers: `sha256:` and the hash in lower-case
  hex. The signature is over the hash rather than the words, so a message of any
  length signs the same amount."
  [text]
  (str "sha256:"
       (apply str
              (for [b (sha256 (.getBytes (or text "") "UTF-8"))
                    :let [v (bit-and (int b) 0xff)]
                    c [(nth hex-digits (bit-shift-right v 4))
                       (nth hex-digits (bit-and v 0xf))]]
                c))))

(defn edit-tags
  "The tags that make a rewrite acceptable: the id this edit is minted under
  and a signature over what it says.

  An edit is a *message* document rather than a mutation one — it carries a
  body — so the fields are the message's own: who, which id, where, the hash
  of the new text, and `edit` naming the message being replaced. The server
  rebuilds this from what arrives and refuses an edit whose signature does not
  verify, or (from an account) one that carries none at all.

  Empty when this connection has no key: a guest signs nothing, and the server
  asks a guest for nothing."
  [target root-msgid text reply-to peer-did]
  (let [{:keys [did]} @signer]
    (or (when did
          (when-let [venue (signing-target target did peer-did)]
            (let [id (event-id)
                  fields (cond-> {"body" (body-hash text)
                                  "edit" root-msgid
                                  "from" did
                                  "msgid" id
                                  "target" venue}
                           (seq (or reply-to "")) (assoc "reply" reply-to))]
              (when-let [sig (sign-bytes (canonical fields))]
                {"+freeq.at/eventid" id
                 "+freeq.at/sig" sig}))))
        {})))

(defn mutation-tags
  "The two tags that make a mutation acceptable: the event id and the signature
  over it. Empty when this connection has no key — a guest signs nothing, and
  the server asks nothing of one."
  [kind target subject emoji peer-did]
  (let [{:keys [did]} @signer]
    (or (when did
          (when-let [signed-target (signing-target target did peer-did)]
            (let [id (event-id)
                  fields (cond-> {"from" did
                                  "kind" kind
                                  "msgid" id
                                  "subject" subject
                                  "target" signed-target}
                           (and (seq (or emoji "")) (not= "delete" kind))
                           (assoc "emoji" emoji))]
              (when-let [sig (sign-bytes (canonical fields))]
                {"+freeq.at/eventid" id
                 "+freeq.at/sig" sig}))))
        {})))
