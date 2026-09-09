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
            [frq.atproto :as atproto]
            [frq.platform :as platform]
            [frq.wire :as wire]
            [jolt.ffi :as ffi]
            [jolt.host :as host]
            [jolt.socket :as socket]))

(def default-broker "https://auth.freeq.at")

;; MSG_NOSIGNAL. A browser opens more connections to a page than it reads —
;; favicon, preconnect, prefetch — and closes them without ceremony. Writing to
;; one of those raises SIGPIPE, which with no handler installed ends the
;; process: the app looked like it wedged the moment the redirect arrived.
(def ^:private no-signal @#'socket/msg-nosignal)

;; ------------------------------------------------------------------ urls

(defn url-encode
  "Percent-encode everything a handle could hold that a query string cannot."
  [s]
  (apply str
         (for [b (.getBytes (or s ""))
               :let [c (char (bit-and (int b) 0xff))]]
           (if (or (Character/isLetterOrDigit c) (#{\- \_ \. \~} c))
             c
             (format "%%%02X" (bit-and (int b) 0xff))))))

(defn login-url [broker handle return-to]
  (let [base (str/replace (or broker default-broker) #"/+$" "")
        handle (-> (or handle "") str/trim (str/replace #"^@" ""))]
    (str base "/auth/login?handle=" (url-encode handle)
         "&return_to=" (url-encode return-to))))

(defn open-browser!
  "Hand the URL to the desktop. A failure here is not fatal — the caller shows
  the URL so it can be opened by hand."
  [url]
  (platform/open-url! url))

;; ------------------------------------------------------------------ capture

(defn- capture-html
  "The page the browser lands on with the handoff in its fragment. Its one job
  is to POST that fragment back, since a fragment never reaches a server.

  `return-url` is the deep link back to the app, or nil where there is nowhere
  to go — on a desktop the browser sits beside the app and the reader switches
  windows. On Android the app is behind the browser and something has to bring
  it forward: the page tries the link on its own, and offers it as a tap for
  the case Chrome refuses a scheme it was not asked for by hand."
  [return-url]
  (str "<!doctype html><meta charset=utf-8><title>frq</title>"
       "<body style=\"font:15px system-ui;background:#242424;color:#fff;padding:40px\">"
       "<p id=m>Finishing sign-in…</p>"
       (when return-url
         (str "<p><a id=b href=\"" return-url "\" hidden "
              "style=\"display:inline-block;padding:12px 20px;border-radius:8px;"
              "background:#5a7fd0;color:#fff;text-decoration:none\">Return to frq</a></p>"))
       "<script>"
       "var h=location.hash.replace(/^#/,'');"
       "var p=new URLSearchParams(h).get('oauth')||h.replace(/^oauth=/,'');"
       "if(!p){document.getElementById('m').textContent='No sign-in payload in this URL.';}"
       "else{fetch('/capture',{method:'POST',body:p})"
       ".then(function(){document.getElementById('m').textContent="
       (if return-url "'Signed in — returning to frq…';" "'Signed in — you can close this tab.';")
       (when return-url
         (str "var b=document.getElementById('b');b.hidden=false;"
              ;; Chrome answers a scripted navigation to a scheme of its own
              ;; only sometimes; the link is there for when it does not.
              "location.href=b.href;"))
       "})"
       ".catch(function(e){document.getElementById('m').textContent='Handoff failed: '+e;});}"
       "</script></body>"))

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
        n (try (socket/c-recv fd buf 16384 no-signal) (catch Exception _ -1))]
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

(defn tokens-of
  "The broker's base64url JSON payload as {:token :broker-token :nick :did
  :handle}."
  [payload]
  (let [json (atproto/b64-decode (str/trim payload))
        token (atproto/json-str json "token")
        broker (atproto/json-str json "broker_token")]
    (when-not (and token broker)
      (throw (ex-info (or (atproto/json-str json "error") "Malformed sign-in payload")
                      {:body json})))
    {:token token
     :broker-token broker
     :nick (atproto/json-str json "nick")
     :did (atproto/json-str json "did")
     :handle (or (atproto/json-str json "handle") "")}))

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
        (let [fd (socket/c-accept server ffi/null ffi/null)]
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

(defn- broker-host [broker]
  (-> (or broker default-broker)
      (str/replace #"^https?://" "")
      (str/split #"/")
      first))

(defn refresh-session
  "Mint a fresh single-use web-token from the durable broker token. This is
  what a reconnect uses; the token from the browser handoff is spent."
  [broker broker-token]
  (let [body (atproto/request (broker-host broker) "/session"
                              (atproto/json-object {"broker_token" broker-token}))
        token (atproto/json-str body "token")]
    (when-not token
      (throw (ex-info (or (atproto/json-str body "message")
                          "Broker session refresh failed — sign in again")
                      {:body body})))
    {:token token
     :broker-token broker-token
     :nick (atproto/json-str body "nick")
     :did (atproto/json-str body "did")
     :handle (or (atproto/json-str body "handle") "")}))
