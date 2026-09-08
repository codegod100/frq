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
            [jolt.mvn-http :as tls]))

;; The endpoint's own cap. Refusing here rather than at the server saves a
;; multi-megabyte upload that was always going to be rejected.
(def max-bytes (* 10 1024 1024))

(defn- file-bytes [path]
  (let [in (java.io.FileInputStream. path)]
    (try (.readAllBytes in)
         (finally (try (.close in) (catch Exception _ nil))))))

(defn- bytes-of [s] (.getBytes (str s)))

(defn- boundary
  "A delimiter of the form the RFC allows, and one no part of this body has in
  it: every byte of it is a hyphen, a letter or a digit, and the parts are a
  PNG and a DID."
  [size]
  (str "----frq" (Math/abs (hash (str size "-frq")))))

(defn- multipart
  "The request body for `fields` (strings) plus the file part, as bytes."
  [bound fields filename content-type file]
  (let [out (java.io.ByteArrayOutputStream.)
        dash (str "--" bound)]
    (doseq [[k v] fields]
      (.write out (bytes-of (str dash "\r\n"
                                 "Content-Disposition: form-data; name=\"" k "\"\r\n\r\n"
                                 v "\r\n"))))
    (.write out (bytes-of (str dash "\r\n"
                               "Content-Disposition: form-data; name=\"file\";"
                               " filename=\"" filename "\"\r\n"
                               "Content-Type: " content-type "\r\n\r\n")))
    (.write out file)
    (.write out (bytes-of (str "\r\n" dash "--\r\n")))
    (.toByteArray out)))

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

(defn- error-message
  "What to show for a response that was not a 2xx. The endpoint answers JSON
  with a `message` or an `error` for the cases a user can do something about —
  not signed in, file too large — and plain text for the rest."
  [status body]
  (let [field (fn [k] (second (re-find (re-pattern (str "\"" k "\"\\s*:\\s*\"([^\"]*)\"")) (or body ""))))
        detail (or (field "message") (field "error") (str/trim (str body)))]
    (str "Upload failed (" status ")"
         (when (seq detail) (str ": " (subs detail 0 (min 200 (count detail))))))))

(defn upload!
  "Upload `path` as `did`'s, returning the URL freeq serves it back at.

  `channel` is passed along when there is one: the server files an upload under
  the conversation it was meant for. Nothing is shared to the PDS or posted to
  Bluesky — those are opt-in fields this client does not send.

  Throws with a message meant to be shown when the upload is refused."
  [host did channel path filename]
  (when (str/blank? (str did))
    (throw (ex-info "Sign in to send a picture — an upload is filed under your account." {})))
  (let [file (file-bytes path)]
    (when (> (alength file) max-bytes)
      (throw (ex-info "That picture is over the 10MB the server takes." {:bytes (alength file)})))
    (tls/ensure-native!)
    (let [bound (boundary (alength file))
          body (multipart bound
                          (cond-> [["did" did]]
                            (seq (str channel)) (conj ["channel" channel]))
                          filename "image/png" file)
          head (bytes-of (str "POST /api/v1/upload HTTP/1.1\r\n"
                              "Host: " host "\r\n"
                              "User-Agent: frq\r\n"
                              "Accept: application/json\r\n"
                              "Content-Type: multipart/form-data; boundary=" bound "\r\n"
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
            (or (second (re-find #"\"url\"\s*:\s*\"([^\"]*)\"" (or payload "")))
                (throw (ex-info "The server took the picture but named no URL for it." {})))
            (throw (ex-info (error-message (or status "no response") payload) {}))))
        (finally (try (tls/tls-close t) (catch Exception _ nil)))))))
