(ns frq.oauth
  "Bluesky OAuth through freeq's auth broker, the way sleek does it.

  The broker owns the OAuth dance with the user's PDS; this client only has to
  get the handoff back. On desktop that is a loopback capture: bind a port, put
  it in `return_to`, open the browser, and serve a page whose only job is to
  POST the `#oauth=` fragment back — the fragment never leaves the browser as a
  query string, so it stays out of logs and history.

  What comes back is a short-lived SASL `web-token` and a durable
  `broker_token`. The web-token is single-use: `/session` mints a fresh one
  from the broker token on every later connection."
  (:require [clojure.string :as str]
            [frq.oauth.core :as core]
            [frq.atproto :as atproto]
            [frq.platform :as platform]
            [frq.wire :as wire]
            [jolt.ffi :as ffi]
            [jolt.host :as host]
            [jolt.socket :as socket]))

;; ------------------------------------------------------------------ urls
;;
;; Moved to `frq.oauth.core` under common/, which is everything about this
;; flow that is not the waiting: the URL, the payload, the session refresh.
;; Re-exported so callers did not move.

(def default-broker core/default-broker)
(def url-encode core/url-encode)
(def login-url core/login-url)
(def tokens-of core/tokens-of)

(defn open-browser!
  "Hand the URL to the desktop. A failure here is not fatal — the caller shows
  the URL so it can be opened by hand."
  [url]
  (platform/open-url! url))

;; ------------------------------------------------------------------ capture

(def capture-html
  "Moved to `frq.oauth.core`: it is a string, and the phone serves the same one
  from a `dart:io` HttpServer. Re-exported so callers did not move."
  core/capture-html)

(defn- respond! [fd body content-type]
  (let [head (str "HTTP/1.1 200 OK\r\nContent-Type: " content-type
                  "\r\nConnection: close\r\nContent-Length: "
                  (count (.getBytes ^String body "UTF-8")) "\r\n\r\n")
        text (str head body)]
    ;; A closed peer is ordinary here, so a failed write is not an error. A
    ;; SHORT write is not ordinary: one c-send used to be the whole of this,
    ;; and the browser was promised a Content-Length the socket had not
    ;; finished delivering — a hung tab on the one page the user is watching
    ;; for the sign-in to land.
    (try (wire/send-all! fd text)
         (catch Exception _ -1))))

(defn- read-request [fd]
  (let [buf (ffi/alloc 16384)
        n (try (wire/recv! fd buf 16384) (catch Exception _ -1))]
    (if (and n (pos? n)) (String. (ffi/read-bytes buf n)) "")))

(defn- bind-loopback!
  "A listening socket on some free loopback port. Returns [fd port]."
  []
  (loop [port 7390]
    (when (> port 7420)
      (throw (ex-info "No free loopback port for the OAuth handoff" {})))
    (let [fd (socket/c-socket 2 1 0)]
      (if (and (>= fd 0)
               (zero? (socket/c-bind fd (#'socket/make-sockaddr-in "127.0.0.1" port) 16))
               (zero? (socket/c-listen fd 4)))
        [fd port]
        (do (socket/c-close fd) (recur (inc port)))))))

(defn await-callback!
  "Serve the loopback capture until the browser posts the handoff back.

  Blocking, so run it off the UI thread. `on-url` is called with the login URL
  once the port is known — that is what the caller shows and opens."
  [broker handle on-url]
  (let [[server port] (bind-loopback!)
        url (login-url broker handle (str "http://127.0.0.1:" port))]
    (try
      (on-url url)
      (loop []
        (let [fd (wire/accept! server)]
          (if (neg? fd)
            (throw (ex-info "Loopback accept failed" {:port port}))
            (let [req (read-request fd)
                  line (first (str/split-lines req))]
              (if (str/starts-with? (or line "") "POST /capture")
                (let [body (str/trim (or (second (str/split req #"\r\n\r\n" 2)) ""))
                      tokens (try (tokens-of body) (catch Exception _ nil))]
                  (respond! fd (if tokens "ok" "bad payload") "text/plain")
                  (socket/c-close fd)
                  ;; A POST that carried nothing usable is not the end of the
                  ;; wait — keep serving, the real handoff may still arrive.
                  (or tokens (recur)))
                (do (respond! fd (capture-html (platform/return-url))
                                 "text/html; charset=utf-8")
                    (socket/c-close fd)
                    (recur)))))))
      (finally (socket/c-close server)))))

;; ------------------------------------------------------------------ session

(defn refresh-session
  "Mint a fresh single-use web-token from the durable broker token."
  [broker broker-token]
  (core/refresh-session-parse
   broker-token
   (let [{:keys [host path body]} (core/refresh-session-req broker broker-token)]
     (atproto/request host path body))))
