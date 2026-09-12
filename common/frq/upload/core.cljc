(ns frq.upload.core
  "Sending a picture: what freeq's media endpoint is asked, and what its answer
  means.

  IRC carries text, so a picture is shared the way every other client shares
  one — it is uploaded, and the link goes in the line. `POST /api/v1/upload`
  takes a multipart form and answers with a URL under `/api/v1/media/…`, served
  back to anyone the link reaches.

  The upload is authorised by the connection itself: the endpoint accepts a DID
  that has a live session on the server, which a signed-in client already has.
  A guest has no DID and cannot upload.

  Everything here is arithmetic over bytes and strings — the boundary, the
  parts, the cap, and reading a URL or a reason out of what came back. The
  sending is not: the desktop writes it down its own TLS and the phone hands it
  to `dart:io`, and neither is this namespace's business.

  Nothing is streamed. An image is at most a few megabytes and the body is
  built in memory, which is what keeps the request one write."
  (:require [clojure.string :as str]
            [frq.io :as io]))

;; The endpoint's own cap. Refusing here rather than at the server saves a
;; multi-megabyte upload that was always going to be rejected.
(def max-bytes (* 10 1024 1024))

(defn boundary
  "A delimiter of the form the RFC allows, and one no part of this body has in
  it: every byte of it is a hyphen, a letter or a digit, and the parts are a
  PNG and a DID.

  Written out of `size` rather than taken from a hash: `hash` is the host's and
  the two hosts do not agree on it, and what this needs is only that it does
  not collide with the bytes beside it."
  [size]
  (str "----frq" size "x" (mod (* 31 (+ size 7)) 100000)))

(defn multipart
  "The request body for `fields` (strings) plus the file part, as a vector of
  bytes."
  [bound fields filename content-type file]
  (let [dash (str "--" bound)
        text (fn [s] (io/utf8-bytes s))]
    (-> (reduce (fn [acc [k v]]
                  (into acc (text (str dash "\r\n"
                                       "Content-Disposition: form-data; name=\"" k "\"\r\n\r\n"
                                       v "\r\n"))))
                []
                fields)
        (into (text (str dash "\r\n"
                         "Content-Disposition: form-data; name=\"file\";"
                         " filename=\"" filename "\"\r\n"
                         "Content-Type: " content-type "\r\n\r\n")))
        (into file)
        (into (text (str "\r\n" dash "--\r\n"))))))

(defn request
  "What to send for this upload: `{:path :content-type :body}`, body in bytes.

  Throws with a message meant to be shown when there is no point sending it —
  a guest has no account to file an upload under, and the endpoint's cap is
  worth refusing on this side of a few megabytes of wire."
  [did channel filename file]
  (when (str/blank? (str did))
    (throw (ex-info "Sign in to send a picture — an upload is filed under your account." {})))
  (when (> (count file) max-bytes)
    (throw (ex-info "That picture is over the 10MB the server takes."
                    {:bytes (count file)})))
  (let [bound (boundary (count file))]
    {:path "/api/v1/upload"
     :content-type (str "multipart/form-data; boundary=" bound)
     :body (multipart bound
                      (cond-> [["did" did]]
                        (seq (str channel)) (conj ["channel" channel]))
                      filename "image/png" file)}))

(defn- field [body k]
  (second (re-find (re-pattern (str "\"" k "\"\\s*:\\s*\"([^\"]*)\"")) (or body ""))))

(defn error-message
  "What to show for a response that was not a 2xx. The endpoint answers JSON
  with a `message` or an `error` for the cases a user can do something about —
  not signed in, file too large — and plain text for the rest."
  [status body]
  (let [detail (or (field body "message") (field body "error") (str/trim (str body)))]
    (str "Upload failed (" status ")"
         (when (seq detail) (str ": " (subs detail 0 (min 200 (count detail))))))))

(defn url-of
  "The URL freeq serves the picture back at, out of a 2xx body. Throws when it
  took the picture and named no URL for it, which leaves nothing to send."
  [body]
  (or (field body "url")
      (throw (ex-info "The server took the picture but named no URL for it." {}))))
