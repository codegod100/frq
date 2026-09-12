(ns frq.av.dial
  "Which SFU to dial, and whether to bother.

  Three things `libjoltmoq` did that were never media at all: building the
  MoQ URL for a freeq server, deciding whether dialling it is worth
  attempting, and minting a per-device call instance. They lived in Rust
  because that is where the media plane was, not because they needed to.

  The rules are transcribed from `av::sfu_moq_dial_url` and
  `av::can_dial_sfu` rather than reinvented, because they are fiddly and
  were already tested on that side: which scheme maps to which, where the
  port survives and where it does not, and what happens to a path that was
  already there."
  (:require [clojure.string :as str]))

;; --- the SFU URL -------------------------------------------------------------

(def ^:private schemes ["ws://" "wss://" "http://" "https://"])

(defn- absolute? [s] (some #(str/starts-with? s %) schemes))

(defn- local-host?
  "localhost and the loopback range, which are dialled over plain HTTP.

  Everything else is assumed to be a public freeq host and therefore TLS —
  the same assumption the Rust made, and the reason a self-hosted server on
  a LAN address needs a scheme spelled out."
  [host]
  (let [h (str/lower-case (or host ""))]
    (or (= h "localhost") (str/starts-with? h "127."))))

(defn- split-url
  "scheme, host[:port], path — enough of a URL for this and no more."
  [u]
  (let [[scheme rest] (str/split u #"://" 2)]
    (when rest
      (let [slash (str/index-of rest "/")
            authority (if slash (subs rest 0 slash) rest)
            ;; A query on the way in is dropped, not merged: the one we
            ;; build replaces it entirely.
            authority (first (str/split authority #"\?"))]
        {:scheme scheme :authority authority}))))

(defn- encode
  "Percent-encode everything that is not unreserved.

  An instance id is eight hex characters and needs none of this, but the id
  is the caller's to choose and a `+` or a space in one would otherwise
  become a different instance on the far side."
  [s]
  (str/join
    (map (fn [ch]
           (let [c (int ch)]
             (if (or (<= 48 c 57) (<= 65 c 90) (<= 97 c 122)
                     (contains? #{\- \_ \. \~} ch))
               (str ch)
               (format "%%%02X" c))))
         s)))

(defn sfu-url
  "The MoQ URL for `server`, or nil when the server is not one a URL can be
  made of.

  `irc.freeq.at:6697` and `wss://irc.freeq.at/irc` both become
  `https://irc.freeq.at/av/moq`. Note what happens to the PORT: on a bare
  host:port form it is dropped, because 6697 is the IRC port and the SFU is
  not there — but on an absolute URL the authority is kept as given, since
  someone who wrote a port into a URL meant it."
  [server jwt instance]
  (let [trimmed (str/trim (or server ""))]
    (when-not (str/blank? trimmed)
      (let [normalised
            (if (absolute? trimmed)
              trimmed
              (let [host (first (str/split trimmed #":"))]
                (if (local-host? host)
                  (str "http://" trimmed)
                  (str "https://" host))))
            {:keys [scheme authority]} (split-url normalised)
            scheme (case scheme
                     ("https" "wss") "https"
                     ("http" "ws")   "http"
                     nil)]
        (when (and scheme (seq authority))
          (let [pairs (cond-> []
                        (seq instance) (conj (str "inst=" (encode instance)))
                        ;; JWTs are base64url and pass through unencoded,
                        ;; which is what freeq-sdk-ffi and freeq-app do.
                        (seq jwt)      (conj (str "jwt=" jwt)))]
            (str scheme "://" authority "/av/moq"
                 (when (seq pairs) (str "?" (str/join "&" pairs))))))))))

(defn can-dial?
  "Whether dialling this server is worth attempting.

  A remote SFU with no token accepts the connection and closes it, and the
  MoQ client then retries in a tight loop that looks, from the outside,
  exactly like a hang. Asking first is cheaper than explaining that."
  [server jwt]
  (if (seq jwt)
    true
    (let [trimmed (str/trim (or server ""))
          host (if (absolute? trimmed)
                 (:authority (split-url trimmed))
                 (-> trimmed (str/split #"/") first (str/split #":") first))
          host (first (str/split (or host "") #":"))]
      (local-host? host))))

;; --- the instance id ---------------------------------------------------------

(defn new-instance
  "A per-device call instance id — eight hex characters.

  Two devices signed in as the same person need different ones, or their
  MoQ broadcast paths collide and each unpublishes the other."
  []
  (format "%08x" (long (rand-int 2147483647))))
