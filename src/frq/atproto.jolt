(ns frq.atproto
  "The AT Protocol half of logging in: handle → DID → PDS → session token.

  freeq's SASL mechanism takes a PDS access token and verifies it against the
  DID document itself (`method: \"pds-session\"`), so this is all the identity
  work the client has to do — no OAuth broker, no key material.

  HTTPS is hand-rolled over jolt.mvn-http's TLS bindings: `fetch` there writes
  to a file and cannot POST. That also means login is desktop-only, for the
  same reason TLS is — there is no libssl to load on Android."
  (:require [clojure.string :as str]
            [jolt.mvn-http :as tls]))

(def directory-host "public.api.bsky.app")
(def plc-host "plc.directory")

;; ------------------------------------------------------------------ HTTP

(defn- read-all!
  "Drain a TLS connection into a string."
  [t]
  (loop [acc ""]
    (let [b (try (tls/tls-read t) (catch Exception _ nil))]
      (if (or (nil? b) (zero? (count b)))
        acc
        (recur (str acc (String. b)))))))

(defn request
  "One HTTPS request, connection-per-request. Returns the response body.
  `body` nil makes it a GET."
  [host path body]
  (tls/ensure-native!)
  (let [t (tls/tls-connect host 443)
        payload (or body "")
        head (str (if body "POST " "GET ") path " HTTP/1.1\r\n"
                  "Host: " host "\r\n"
                  "User-Agent: frq\r\n"
                  "Accept: application/json\r\n"
                  (when body
                    (str "Content-Type: application/json\r\n"
                         "Content-Length: " (count (.getBytes payload)) "\r\n"))
                  "Connection: close\r\n\r\n")]
    (try
      (tls/tls-write t (.getBytes (str head payload)))
      (let [resp (read-all! t)
            [_ b] (str/split resp #"\r\n\r\n" 2)]
        (or b ""))
      (finally (try (tls/tls-close t) (catch Exception _ nil))))))

;; ------------------------------------------------------------------ JSON

(defn json-str
  "The string value of a top-level JSON field, or nil.

  Enough of a parser for the four fields this namespace reads. Escapes are
  passed through unchanged — none of a DID, a handle, a URL or a JWT contains
  one."
  [json field]
  (let [m (re-find (re-pattern (str "\"" field "\"\\s*:\\s*\"([^\"]*)\"")) (or json ""))]
    (second m)))

(defn json-num
  "The numeric value of a top-level JSON field, or nil.

  Written out as a string rather than parsed into a number: the counts on a
  profile are only ever printed, and \"1204\" is what printing them wants."
  [json field]
  (second (re-find (re-pattern (str "\"" field "\"\\s*:\\s*(-?[0-9]+)")) (or json ""))))

(defn json-unescape
  "A JSON string body back to the text it stands for.

  `json-str` hands back the escapes as they were written, which is right for a
  DID or a URL — none of them contains one — and wrong for a bio, where the
  line breaks someone typed arrive as backslash-n. Only the escapes a bio can
  carry are undone; a stray backslash is left alone rather than eaten."
  [s]
  (str/replace (or s "") #"\\(u[0-9a-fA-F]{4}|.)"
               (fn [[whole esc]]
                 (case (first esc)
                   \n "\n"
                   \t "\t"
                   \r "\r"
                   \b "\b"
                   \f "\f"
                   \" "\""
                   \\ "\\"
                   \/ "/"
                   \u (str (char (Integer/parseInt (subs esc 1) 16)))
                   whole))))

(defn- json-escape [s]
  (-> (or s "")
      (str/replace "\\" "\\\\")
      (str/replace "\"" "\\\"")))

(defn json-object
  "A flat JSON object from a map of string keys to string values."
  [m]
  (str "{" (str/join "," (for [[k v] m] (str "\"" k "\":\"" (json-escape v) "\""))) "}"))

;; ------------------------------------------------------------------ identity

(defn resolve-handle
  "A handle (alice.bsky.social) to its DID. A DID passes through untouched."
  [handle]
  (let [h (str/trim (or handle ""))]
    (if (str/starts-with? h "did:")
      h
      (let [body (request directory-host
                          (str "/xrpc/com.atproto.identity.resolveHandle?handle=" h)
                          nil)]
        (or (json-str body "did")
            (throw (ex-info (str "Could not resolve handle " h) {:handle h :body body})))))))

(defn pds-endpoint
  "The DID's PDS service endpoint, from its DID document.

  did:plc documents come from the PLC directory; did:web ones from the domain
  itself, which is the whole of what did:web means."
  [did]
  (let [doc (cond
              (str/starts-with? did "did:plc:") (request plc-host (str "/" did) nil)
              (str/starts-with? did "did:web:")
              (request (subs did (count "did:web:")) "/.well-known/did.json" nil)
              :else (throw (ex-info (str "Unsupported DID method: " did) {:did did})))
        ;; The document lists several services; the PDS is the one whose entry
        ;; carries a serviceEndpoint next to type AtprotoPersonalDataServer.
        endpoint (or (second (re-find #"\"AtprotoPersonalDataServer\"\s*,\s*\"serviceEndpoint\"\s*:\s*\"([^\"]*)\"" doc))
                     (second (re-find #"\"serviceEndpoint\"\s*:\s*\"([^\"]*)\"[^}]*\"AtprotoPersonalDataServer\"" doc))
                     (json-str doc "serviceEndpoint"))]
    (or endpoint
        (throw (ex-info (str "No PDS endpoint for " did) {:did did})))))

(defn- host-of [url]
  (-> url (str/replace #"^https?://" "") (str/split #"/") first))

(defn create-session
  "Sign in to the PDS with an app password. Returns
  {:did :handle :access-jwt :pds}.

  The password goes to the user's own PDS and nowhere else — freeq never sees
  it, and verifies the token it gets by asking that same PDS."
  [identifier password]
  (let [did (resolve-handle identifier)
        pds (pds-endpoint did)
        body (request (host-of pds)
                      "/xrpc/com.atproto.server.createSession"
                      (json-object {"identifier" identifier "password" password}))
        jwt (json-str body "accessJwt")]
    (when-not jwt
      (throw (ex-info (or (json-str body "message") "Sign-in failed") {:body body})))
    {:did (or (json-str body "did") did)
     :handle (or (json-str body "handle") identifier)
     :access-jwt jwt
     :pds pds}))

;; ------------------------------------------------------------------ base64url

(def ^:private alphabet
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

(defn b64-encode
  "base64url of a string, unpadded — what SASL and freeq's challenge use.
  Hand-rolled rather than java.util.Base64: the host classes jolt registers are
  not all there in a cross-compiled boot image, and this is three lines."
  [s]
  (let [bs (mapv #(bit-and (int %) 0xff) (.getBytes s))]
    (apply str
           (for [group (partition-all 3 bs)
                 :let [[a b c] group
                       n (count group)
                       v (+ (bit-shift-left a 16)
                            (bit-shift-left (or b 0) 8)
                            (or c 0))]
                 i (range (inc n))]
             (nth alphabet (bit-and (bit-shift-right v (* 6 (- 3 i))) 0x3f))))))

(defn b64-decode
  "base64url back to a string. Padding is tolerated and ignored."
  [s]
  (let [idx (into {} (map-indexed (fn [i c] [c i]) alphabet))
        vals (keep idx (remove #{\=} (seq (or s ""))))
        bytes (for [group (partition-all 4 vals)
                    :let [n (count group)
                          v (reduce (fn [acc x] (+ (bit-shift-left acc 6) x))
                                    0
                                    (concat group (repeat (- 4 n) 0)))]
                    i (range (dec n))]
                (bit-and (bit-shift-right v (* 8 (- 2 i))) 0xff))]
    (String. (byte-array (map unchecked-byte bytes)))))

(defn sasl-response
  "The base64url SASL payload for a session, either kind freeq takes.

  A `:pds-session` carries the PDS token, the DID it belongs to, its PDS, and
  the server's own nonce echoed back so the token cannot be replayed at another
  server. A `:web-token` from the auth broker carries only the token — the
  server looks the DID up in its own token store, which is why the field is
  sent empty rather than guessed at."
  [session nonce]
  (b64-encode
   (if (= :web-token (:kind session))
     (json-object {"did" "" "method" "web-token" "signature" (:token session)})
     (json-object {"did" (:did session)
                   "signature" (:access-jwt session)
                   "method" "pds-session"
                   "pds_url" (:pds session)
                   "challenge_nonce" nonce}))))
