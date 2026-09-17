(ns frq.atproto.core
  "The AT Protocol half of logging in: handle → DID → PDS → session token.

  freeq's SASL mechanism takes a PDS access token and verifies it against the
  DID document itself (`method: \"pds-session\"`), so this is all the identity
  work the client has to do — no OAuth broker, no key material.

  Shared, and the HTTP is not. The desktop's `request` is a blocking write and
  a read on a TLS socket; the phone's is a Future. Neither shape can be written
  once, so what lives here is everything either side of the wire: the JSON, the
  base64url, the SASL payloads, and — for each step of the flow — a pure
  function that says what to ask for and a pure function that reads the answer.

  So `resolve-handle` is `resolve-handle-req` and `resolve-handle-parse`, and
  the platform supplies only the middle. `frq.atproto` on the desktop puts
  them back together into the same three functions its callers always had, and
  re-exports everything here under its own name — the same arrangement
  `frq.irc` and `frq.irc.parse` are in."
  (:require [clojure.string :as str]
            [frq.io :as io]))

(def directory-host "public.api.bsky.app")
(def plc-host "plc.directory")

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

(def ^:private hex-digits
  ;; A lookup rather than a radix parse. `Integer/parseInt` is Java and there
  ;; is none of it under ClojureDart; four digits of hex is a fold.
  (into {} (map-indexed (fn [i c] [c i]) "0123456789abcdef")))

(defn- hex->int [s]
  (reduce (fn [acc c] (+ (* 16 acc) (get hex-digits (first (str/lower-case (str c))) 0)))
          0
          (seq s)))

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
                   \u (str (char (hex->int (subs esc 1))))
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


;; ------------------------------------------------------------------ identity
;;
;; Each step is a pair: a `-req` that describes the call and a `-parse` that
;; reads the body. Both are pure, so the flow is testable without a socket and
;; is the same on both platforms — only who performs the request differs.

(defn resolve-handle-req
  "What to ask to turn a handle into a DID, or nil when it is already one and
  there is nothing to ask."
  [handle]
  (let [h (str/trim (or handle ""))]
    (when-not (str/starts-with? h "did:")
      {:host directory-host
       :path (str "/xrpc/com.atproto.identity.resolveHandle?handle=" h)})))

(defn resolve-handle-parse
  "The DID out of that answer. A handle that is already a DID needs no call and
  passes through, which is why `body` may be nil."
  [handle body]
  (let [h (str/trim (or handle ""))]
    (if (str/starts-with? h "did:")
      h
      (or (json-str body "did")
          (throw (ex-info (str "Could not resolve handle " h) {:handle h :body body}))))))

(defn pds-doc-req
  "Where the DID document lives. did:plc documents come from the PLC
  directory; did:web ones from the domain itself, which is the whole of what
  did:web means."
  [did]
  (cond
    (str/starts-with? did "did:plc:") {:host plc-host :path (str "/" did)}
    (str/starts-with? did "did:web:") {:host (subs did (count "did:web:"))
                                       :path "/.well-known/did.json"}
    :else (throw (ex-info (str "Unsupported DID method: " did) {:did did}))))

(defn pds-endpoint-parse
  "The PDS service endpoint out of a DID document.

  The document lists several services; the PDS is the one whose entry carries a
  serviceEndpoint next to type AtprotoPersonalDataServer."
  [did doc]
  (or (second (re-find #"\"AtprotoPersonalDataServer\"\s*,\s*\"serviceEndpoint\"\s*:\s*\"([^\"]*)\"" doc))
      (second (re-find #"\"serviceEndpoint\"\s*:\s*\"([^\"]*)\"[^}]*\"AtprotoPersonalDataServer\"" doc))
      (json-str doc "serviceEndpoint")
      (throw (ex-info (str "No PDS endpoint for " did) {:did did}))))

(defn host-of [url]
  (-> url (str/replace #"^https?://" "") (str/split #"/") first))

(defn create-session-req
  "Sign in to the PDS with an app password.

  The password goes to the user's own PDS and nowhere else — freeq never sees
  it, and verifies the token it gets by asking that same PDS."
  [pds identifier password]
  {:host (host-of pds)
   :path "/xrpc/com.atproto.server.createSession"
   :body (json-object {"identifier" identifier "password" password})})

(defn create-session-parse
  "{:did :handle :access-jwt :pds} out of that answer."
  [identifier did pds body]
  (let [jwt (json-str body "accessJwt")]
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
  not all there in a cross-compiled boot image, there is no java.util at all
  under ClojureDart, and this is three lines. The bytes come from `frq.io`,
  which is the one part of it that differs."
  [s]
  (let [bs (vec (io/utf8-bytes s))]
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
    (io/utf8-string bytes)))

(defn sasl-response
  "The base64url SASL payload for a session, either kind freeq takes.

  A `:pds-session` carries the PDS token, the DID it belongs to, its PDS, and
  the server's own nonce echoed back so the token cannot be replayed at another
  server. A `:web-token` from the auth broker carries only the token — the
  server looks the DID up in its own token store, which is why the field is
  sent empty rather than guessed at."
  [session nonce]
  (b64-encode
   (case (:kind session)
     :web-token
     (json-object {"did" "" "method" "web-token" "signature" (:token session)})

     ;; An OAuth access token, which the server cannot simply present to the
     ;; PDS: a DPoP token is bound to a key, and the holder has to prove it.
     ;; So the proof travels with it. freeq calls getSession with our token
     ;; and our proof, and the PDS checks that the proof names that method,
     ;; that URL and that token — which is what lets a proof be minted for a
     ;; request this client never makes.
     ;;
     ;; `:dpop-proof` is prepared by the caller rather than built here,
     ;; because minting one is asynchronous and this is not: it is WebCrypto
     ;; on the web and nothing at all on the other two targets.
     :pds-oauth
     (json-object {"did" (:did session)
                   "signature" (:access-jwt session)
                   "method" "pds-oauth"
                   "pds_url" (:pds session)
                   "dpop_proof" (str (:dpop-proof session))
                   "challenge_nonce" nonce})

     (json-object {"did" (:did session)
                   "signature" (:access-jwt session)
                   "method" "pds-session"
                   "pds_url" (:pds session)
                   "challenge_nonce" nonce}))))
