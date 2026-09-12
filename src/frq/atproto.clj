(ns frq.atproto
  "The desktop's AT Protocol: `frq.atproto.core` with a socket under it.

  The protocol itself moved to common/ — the JSON, the base64url, the SASL
  payloads, and a `-req`/`-parse` pair per step of the flow. What could not
  move is this: HTTPS hand-rolled over jolt.mvn-http's TLS bindings, because
  `fetch` there writes to a file and cannot POST. That is also why sign-in is
  desktop-only on jolt — there is no libssl to load on Android — and why the
  phone has `frq.atproto.dart`, where TLS is in the runtime.

  Everything in core is re-exported here, so the twenty-nine call sites that
  say `atproto/json-str` or `atproto/request` did not move."
  (:require [clojure.string :as str]
            [frq.atproto.core :as core]
            [jolt.mvn-http :as tls]))

(def directory-host core/directory-host)
(def plc-host core/plc-host)
(def json-str core/json-str)
(def json-num core/json-num)
(def json-unescape core/json-unescape)
(def json-object core/json-object)
(def b64-encode core/b64-encode)
(def b64-decode core/b64-decode)
(def sasl-response core/sasl-response)

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

(defn- fetch
  "Perform one `-req` descriptor."
  [{:keys [host path body]}]
  (request host path body))

;; ------------------------------------------------------------------ identity
;;
;; The flow, put back together: core says what to ask and what the answer
;; means, and this is the only part that touches a socket.

(defn resolve-handle
  "A handle (alice.bsky.social) to its DID. A DID passes through untouched."
  [handle]
  (core/resolve-handle-parse
   handle
   (when-let [req (core/resolve-handle-req handle)] (fetch req))))

(defn pds-endpoint
  "The DID's PDS service endpoint, from its DID document."
  [did]
  (core/pds-endpoint-parse did (fetch (core/pds-doc-req did))))

(defn create-session
  "Sign in to the PDS with an app password. Returns
  {:did :handle :access-jwt :pds}."
  [identifier password]
  (let [did (resolve-handle identifier)
        pds (pds-endpoint did)]
    (core/create-session-parse
     identifier did pds
     (fetch (core/create-session-req pds identifier password)))))
