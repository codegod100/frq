(ns frq.upload
  "Sending a picture: freeq's media endpoint, over the same hand-rolled TLS the
  rest of the client speaks.

  IRC carries text, so a picture is shared the way every other client shares
  one — it is uploaded, and the link goes in the line. freeq's
  `POST /api/v1/upload` takes a multipart form and answers with a URL under
  `/api/v1/media/…`, signed and served back to anyone the link reaches.

  The upload is authorised by the connection itself: the endpoint accepts a DID
  that has a live session on the server, which a signed-in client already has.
  A guest has no DID and cannot upload — the same line TLS draws everywhere
  else in this client.

  Nothing here is streamed: an image is at most a few megabytes and the body is
  built in memory, which is what keeps the request one write."
  (:require [clojure.string :as str]
            [frq.upload.core :as core]
            [jolt.mvn-http :as tls]))

;; The endpoint's own cap. Refusing here rather than at the server saves a
;; multi-megabyte upload that was always going to be rejected.
(def max-bytes core/max-bytes)

(defn- file-bytes [path]
  (let [in (java.io.FileInputStream. path)]
    (try (.readAllBytes in)
         (finally (try (.close in) (catch Exception _ nil))))))

(defn- bytes-of [s] (.getBytes (str s)))

(defn- read-all!
  "Drain a TLS connection into a string. The response is a short JSON body, so
  it is read whole rather than by Content-Length."
  [t]
  (loop [acc ""]
    (let [b (try (tls/tls-read t) (catch Exception _ nil))]
      (if (or (nil? b) (zero? (count b)))
        acc
        (recur (str acc (String. b)))))))

(defn- status-of [resp]
  (some-> (re-find #"^HTTP/1\.[01] (\d{3})" (or resp "")) second))

(defn upload!
  "Upload `path` as `did`'s, returning the URL freeq serves it back at.

  `frq.upload.core` builds the request and reads the answer; what is left here
  is this backend's way of sending one — jolt's own TLS, in a single write.

  `channel` is passed along when there is one: the server files an upload under
  the conversation it was meant for. Nothing is shared to the PDS or posted to
  Bluesky — those are opt-in fields this client does not send."
  [host did channel path filename]
  (let [{:keys [path content-type body]}
        (core/request did channel filename (vec (file-bytes path)))
        body (byte-array body)]
    (tls/ensure-native!)
    (let [head (bytes-of (str "POST " path " HTTP/1.1\r\n"
                              "Host: " host "\r\n"
                              "User-Agent: frq\r\n"
                              "Accept: application/json\r\n"
                              "Content-Type: " content-type "\r\n"
                              "Content-Length: " (alength body) "\r\n"
                              "Connection: close\r\n\r\n"))
          t (tls/tls-connect host 443)]
      (try
        ;; Head and body in one write: the server reads a request, not two.
        (let [req (java.io.ByteArrayOutputStream.)]
          (.write req head)
          (.write req body)
          (tls/tls-write t (.toByteArray req)))
        (let [resp (read-all! t)
              status (status-of resp)
              [_ payload] (str/split resp #"\r\n\r\n" 2)]
          (if (and status (str/starts-with? status "2"))
            (core/url-of payload)
            (throw (ex-info (core/error-message (or status "no response") payload) {}))))
        (finally (try (tls/tls-close t) (catch Exception _ nil)))))))
