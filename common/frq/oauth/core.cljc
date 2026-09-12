(ns frq.oauth.core
  "The broker flow, minus the waiting: login URL in, handoff payload out.

  freeq's auth broker does the AT Protocol OAuth and hands back a payload; all
  a client does is build the URL, open it, and read what comes back. Building
  and reading are the same everywhere and live here. Catching the handoff is
  not: the desktop listens on a loopback socket and the phone cannot — see
  `frq.oauth` for what that means.

  `refresh-session` is a `-req`/`-parse` pair for the same reason
  `frq.atproto.core`'s steps are: one platform waits on a socket and the other
  on a Future, and neither shape is writable once."
  (:require [clojure.string :as str]
            [frq.atproto.core :as atproto]
            [frq.io :as io]))

(def default-broker "https://auth.freeq.at")

;; ------------------------------------------------------------------ urls

(def ^:private hex "0123456789ABCDEF")

(defn- unreserved?
  "RFC 3986's unreserved set, as byte values: A-Z a-z 0-9 - _ . ~

  By number rather than `Character/isLetterOrDigit`, which is Java and would
  also say yes to é — and a percent-encoder that passes é through has not
  encoded anything."
  [b]
  (or (<= 48 b 57) (<= 65 b 90) (<= 97 b 122)
      (contains? #{45 95 46 126} b)))

(defn url-encode
  "Percent-encode everything a handle could hold that a query string cannot.

  Over UTF-8 bytes, not characters: a non-ASCII handle is several bytes and
  each one is encoded separately, which is what the spec says and what the
  broker expects."
  [s]
  (apply str
         (for [b (io/utf8-bytes s)]
           (if (unreserved? b)
             (char b)
             (str "%" (nth hex (quot b 16)) (nth hex (mod b 16)))))))

(defn login-url [broker handle return-to]
  (let [base (str/replace (or broker default-broker) #"/+$" "")
        handle (-> (or handle "") str/trim (str/replace #"^@" ""))]
    (str base "/auth/login?handle=" (url-encode handle)
         "&return_to=" (url-encode return-to))))

(defn broker-host [broker]
  (-> (or broker default-broker)
      (str/replace #"^https?://" "")
      (str/split #"/")
      first))

;; ------------------------------------------------------------------ handoff

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

;; ------------------------------------------------------------------ session

(defn refresh-session-req
  "Mint a fresh single-use web-token from the durable broker token. This is
  what a reconnect uses; the token from the browser handoff is spent."
  [broker broker-token]
  {:host (broker-host broker)
   :path "/session"
   :body (atproto/json-object {"broker_token" broker-token})})

(defn refresh-session-parse [broker-token body]
  (let [token (atproto/json-str body "token")]
    (when-not token
      (throw (ex-info (or (atproto/json-str body "message")
                          "Broker session refresh failed — sign in again")
                      {:body body})))
    {:token token
     :broker-token broker-token
     :nick (atproto/json-str body "nick")
     :did (atproto/json-str body "did")
     :handle (or (atproto/json-str body "handle") "")}))


;; ------------------------------------------------------------ the capture page

(defn capture-html
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
