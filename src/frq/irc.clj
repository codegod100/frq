(ns frq.irc
  "A small IRC client for freeq servers, over plain TCP.

  Two transports, behind one `read-chunk!`/`write!` pair. TLS is the default —
  jolt.mvn-http carries OpenSSL bindings for its own HTTPS fetching, and they
  are just as good for an IRC socket, so `:6697` works. Plain TCP is the raw
  BSD calls: socket, connect, send, recv.

  The raw calls rather than the java.net.Socket surface jolt.socket registers,
  because that surface does not work on Android — nor does mvn-http's
  getaddrinfo path, which is why TLS is desktop-only there. `socket()` and
  `connect()` themselves are fine on both, so this is what the phone gets.

  One future reads, the UI thread writes; nothing here knows about the UI.
  `connect!` takes an `on-msg` fn and returns a connection map that
  `send-line!` and `close!` accept."
  (:require [clojure.string :as str]
            [frq.atproto :as atproto]
            [frq.irc.parse :as parse]
            [frq.irc.handshake :as handshake]
            [frq.irc.mutate :as mutate]
            [frq.msgsig :as msgsig]
            [frq.wire :as wire]
            [jolt.ffi :as ffi]
            [jolt.host :as host]
            [jolt.mvn-http :as tls]
            [jolt.socket :as socket]))

(def ^:private af-inet 2)
(def ^:private sock-stream 1)
(def ^:private buffer-size 8192)

;; jolt's TLS sockets carry a 30-second receive timeout, so a quiet connection
;; reads nothing without being closed. These decide how long that is allowed to
;; go on: past `idle-ping-secs` we ask the server whether it is still there,
;; and past `idle-dead-secs` with no answer we conclude it is not.
(def ^:private idle-ping-secs 45)
(def ^:private idle-dead-secs 90)

;; How long a TLS read waits before giving the thread back. It is also how long
;; an outgoing line can sit in the outbox, so it wants to be short: the reader
;; owns the connection, and this is how often it looks at what there is to send.
(def ^:private tls-poll-ms 200)

(defn- secs-since [t] (quot (- (host/mono-nanos) t) 1000000000))

;; ---------------------------------------------------------------- parsing
;;
;; Moved to `frq.irc.parse` under common/, so ClojureDart compiles it too —
;; the wire format is the same on a phone, and only the socket under it is
;; not. Re-exported here rather than left to the callers: `irc/tag-value` and
;; `irc/nick-of` are read in twenty-three places across frq.state and frq.av,
;; and none of them care which file it lives in.

(def parse-line parse/parse-line)
(def unescape-tag parse/unescape-tag)
(def escape-tag-value parse/escape-tag-value)
(def tag-value parse/tag-value)
(def nick-of parse/nick-of)

;; ---------------------------------------------------------------- transport

(defn- write!
  "Bytes out, whichever transport this is. TLS callers go through the outbox
  instead — see `send-line!`."
  [conn text]
  (if (= :tls (:kind conn))
    (tls/tls-write (:tls conn) (.getBytes text))
    (wire/send-all! (:fd conn) text)))

(defn- read-chunk!
  "Block for the next chunk as a string, or nil at end of stream."
  [conn]
  (if (= :tls (:kind conn))
    (let [b (try (tls/tls-read (:tls conn)) (catch Exception _ nil))]
      (when (and b (pos? (count b))) (String. b)))
    (let [buf (:buf conn)
          n (try (wire/recv! (:fd conn) buf buffer-size) (catch Exception _ -1))]
      (when (and n (pos? n)) (String. (ffi/read-bytes buf n))))))

(defn send-line!
  "Send a raw IRC line. Safe from any thread.

  On TLS the line is queued rather than written: OpenSSL is driven here through
  a pair of memory BIOs, and a write issued while the reader thread is parked
  inside SSL_read is simply lost — the call reports success and the server
  never sees the line. So the reader thread owns the connection in both
  directions and drains this queue between reads. A raw socket has no such
  problem, and writes straight through."
  [conn line]
  (let [text (str line "\r\n")]
    (if (= :tls (:kind conn))
      (locking (:lock conn) (swap! (:outbox conn) conj text))
      (locking (:lock conn) (write! conn text)))))

(declare flush-outbox-tls!)

(defn- flush-outbox!
  "Write whatever has been queued. Only ever called on the reader thread.

  Only a TLS connection has a queue: a raw socket is written straight from
  whichever thread is sending, so there is nothing here to drain."
  [conn]
  (when (:outbox conn)
    (flush-outbox-tls! conn)))

(defn- flush-outbox-tls! [conn]
  (let [pending (locking (:lock conn)
                  (let [q @(:outbox conn)]
                    (reset! (:outbox conn) [])
                    q))]
    (doseq [text pending]
      (when (System/getenv "FRQ_TRACE")
        (binding [*out* *err*] (println "frq/irc: >>" (str/trimr text))))
      (try (write! conn text)
           (catch Exception e
             (binding [*out* *err*] (println "frq/irc: write failed:" (or (ex-message e) (str e))))
             ;; Put it back: a write that failed for a transient reason is
             ;; worth another turn of the loop.
             (locking (:lock conn) (swap! (:outbox conn) conj text)))))))

(defn- reader-loop!
  "Read until the connection ends, splitting on CRLF and dispatching each
  complete line. PING is answered here so a busy UI never times the link out;
  everything else goes to `on-msg`.

  Nothing to read is not the end of the connection. On TLS it usually means the
  30-second receive timeout elapsed on a quiet channel — reading that as EOF is
  what used to leave the app connected in appearance only: sends went nowhere
  while the buffer still filled in with what the user typed. So a quiet stretch
  gets a PING, and only silence after that counts as gone."
  [conn on-msg]
  (loop [acc "" last-data (host/mono-nanos) pinged? false]
    (flush-outbox! conn)
    (let [chunk (read-chunk! conn)]
      (cond
        ;; A plain socket has no timeout, so nothing to read really is the end.
        (and (nil? chunk) (not= :tls (:kind conn)))
        (on-msg {:command "*DISCONNECTED*" :params []})

        (nil? chunk)
        (let [idle (secs-since last-data)]
          (cond
            (and pinged? (> idle idle-dead-secs))
            (on-msg {:command "*DISCONNECTED*" :params []})

            (and (not pinged?) (> idle idle-ping-secs))
            (do (try (send-line! conn "PING :frq") (catch Exception _ nil))
                (recur acc last-data true))

            :else (recur acc last-data pinged?)))

        :else
        (let [acc (str acc chunk)
              lines (str/split acc #"\r?\n" -1)
              complete (butlast lines)]
          (doseq [line complete :when (seq (str/trim line))]
            (when (System/getenv "FRQ_TRACE")
              (binding [*out* *err*] (println "frq/irc: <<" (subs line 0 (min 100 (count line))))))
            (let [msg (parse-line line)]
              (when (= "PING" (:command msg))
                (send-line! conn (str "PONG :" (first (:params msg)))))
              (on-msg (assoc msg :raw line))))
          (recur (last lines) (host/mono-nanos) false))))))

(defn- open
  "Dial `host`:`port`, over TLS unless `tls?` is false."
  [host port tls? nick]
  (if tls?
    (do (tls/ensure-native!)
        (let [t (tls/tls-connect host (int port))]
          ;; Without a short timeout the reader parks for 30 seconds at a time,
          ;; which is 30 seconds of nothing being sent.
          (try (#'tls/set-timeouts! (:sock t) tls-poll-ms) (catch Exception _ nil))
          {:kind :tls :tls t :outbox (atom [])
           :lock (Object.) :nick nick :caps (atom #{})}))
    (let [ip (#'socket/ip->str (socket/resolve-host host))
          fd (socket/c-socket af-inet sock-stream 0)]
      (when (neg? fd) (throw (ex-info "socket() failed" {:host host})))
      (let [rc (wire/connect! fd (#'socket/make-sockaddr-in ip (int port)) 16)]
        (when (neg? rc)
          (socket/c-close fd)
          (throw (ex-info "connect() failed" {:host host :ip ip :port port}))))
      {:kind :plain :fd fd :buf (ffi/alloc buffer-size)
       :lock (Object.) :nick nick :caps (atom #{})})))

(def cap-acked?
  "Whether the server agreed to `cap` on this connection."
  (fn [conn cap]
    (handshake/acked? (when-let [caps (:caps conn)] @caps) cap)))

(defn- cap-step!
  "Drive capability negotiation, and the SASL exchange inside it when there is
  a session to authenticate with. Returns the message unchanged, so the caller
  can go on handling it.

  All of the deciding is `frq.irc.handshake`, which is shared: it answers with
  the lines to send and this writes them. What is left here is the writing and
  the atom the acked set lives in."
  [conn session msg]
  (let [caps (:caps conn)
        {:keys [send] next-caps :caps}
        (handshake/step {:session session :caps (when caps @caps)} msg)]
    (when caps (reset! caps next-caps))
    (doseq [line send] (send-line! conn line)))
  msg)

(defn connect!
  "Open a connection, register `nick`, and start the reader.

  With a `session` from `frq.atproto/create-session` the registration runs the
  SASL exchange first and the connection is bound to that DID; without one it
  is an ordinary guest. `tls?` defaults to true — freeq's TLS listener is
  :6697, plain is :6667."
  ([host port nick on-msg] (connect! host port nick on-msg true nil))
  ([host port nick on-msg tls?] (connect! host port nick on-msg tls? nil))
  ([host port nick on-msg tls? session]
   (let [conn (open host port tls? nick)
         on-msg (fn [msg] (on-msg (cap-step! conn session msg)))]
     (future
       (try (reader-loop! conn on-msg)
            (catch Exception e
              (on-msg {:command "*ERROR*" :params [(str e)]}))))
     ;; CAP first: registration waits for CAP END, which negotiation sends once
     ;; it has an answer — after the SASL exchange, when there is one.
     (send-line! conn "CAP LS 302")
     (send-line! conn (str "NICK " nick))
     (send-line! conn (str "USER " nick " 0 * :" nick))
     conn)))

(defn join! [conn channel] (send-line! conn (str "JOIN " channel)))
(defn part! [conn channel] (send-line! conn (str "PART " channel)))

(defn privmsg!
  "Say something. With `reply-to`, say it as an answer to that message: the
  `+draft/reply` tag is what every other freeq client reads to thread it, and
  what this one draws its chips from."
  ([conn target text] (privmsg! conn target text nil))
  ([conn target text reply-to]
   (send-line! conn (str (when (seq reply-to) (str "@+draft/reply=" reply-to " "))
                         "PRIVMSG " target " :" text))))

(defn edit!
  "Rewrite something already said. The line is `frq.irc.mutate`'s; this writes
  it."
  ([conn target msgid text] (edit! conn target msgid text nil))
  ([conn target msgid text peer-did]
   (send-line! conn (mutate/edit-line target msgid text peer-did))))

(defn tagmsg!
  "A message that is only tags: how freeq carries a reaction, a typing hint or
  a delete. `tags` is a map of name to value, sent in no particular order — the
  server reads them by name."
  [conn target tags]
  (let [pairs (for [[k v] tags] (str k "=" (escape-tag-value v)))]
    (send-line! conn (str "@" (str/join ";" pairs) " TAGMSG " target))))

(defn react!
  "Put `emoji` on the message `msgid`, for everyone in `target` to see.

  The line is `frq.irc.mutate`'s; this writes it."
  ([conn target msgid emoji] (react! conn target msgid emoji nil))
  ([conn target msgid emoji peer-did]
   (send-line! conn (mutate/react-line target msgid emoji peer-did))))

(defn unreact!
  "Take it off again."
  ([conn target msgid emoji] (unreact! conn target msgid emoji nil))
  ([conn target msgid emoji peer-did]
   (send-line! conn (mutate/unreact-line target msgid emoji peer-did))))


(defn close! [conn]
  ;; Written straight out rather than queued: the reader may already be gone,
  ;; and there is nothing left to lose if this one is.
  (try (locking (:lock conn) (write! conn "QUIT :frq\r\n")) (catch Exception _ nil))
  (try (if (= :tls (:kind conn))
         (tls/tls-close (:tls conn))
         (do (socket/c-close (:fd conn))
             (ffi/free (:buf conn))))
       (catch Exception _ nil)))
