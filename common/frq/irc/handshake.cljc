(ns frq.irc.handshake
  "CAP negotiation and the SASL exchange inside it, as lines to send.

  This is the whole of signing in, and none of it is a socket: every step is
  the same question — given what the server just said, what does this client
  say back. So it answers with lines and the caller writes them, which is the
  one part that differs. The desktop writes them from a blocking reader
  thread and the phone from a `Stream`, and neither has any say in what they
  are.

  What it reasons over is shared too, which is why this could move at all:
  `frq.atproto.core` builds the SASL payload and `frq.msgsig` mints the
  signing key. The last thing in the chain was the transport, and the
  transport is the caller's."
  (:require [clojure.string :as str]
            [frq.atproto.core :as atproto]
            [frq.msgsig :as msgsig]))

(def sasl-chunk
  "AUTHENTICATE takes at most 400 characters a line."
  400)

(def wanted-caps
  "What this client can use, and why a guest connection negotiates at all.

  `server-time`: without it a replayed backlog arrives untimed and every old
  line reads as having just been said. `account-tag`: it puts the sender's DID
  on the message, which is the only identity a client is given — a nick is
  whatever someone chose today, and the hostmask carries eight characters of a
  DID, too few to resolve. Both need `message-tags` beside them, since IRCv3
  sends tags only to clients that asked for tags at all; either one alone is
  ACKed and then nothing arrives.

  `echo-message`: the server sends our own lines back to us, which is the only
  way this client learns the msgid of something it said. Without it our own
  messages sit in the buffer with no id, and a reaction or a reply aimed at one
  has nothing to name — the pill appears here and nobody else ever sees it.

  `freeq.at/msgsig`: what lets a signed-in account react at all. freeq answers
  an unsigned mutation from an account with
  `FAIL TAGMSG SIGNATURE_REQUIRED`, and this cap is how a client says it can
  register a key and sign one."
  ["message-tags" "server-time" "account-tag" "echo-message" "freeq.at/msgsig"])

(defn sasl-lines
  "A payload split the way AUTHENTICATE wants it.

  One that lands exactly on the boundary is followed by a bare `+`, so the
  server knows it ended rather than waiting for a continuation that is not
  coming."
  [payload]
  (loop [rest payload out []]
    (if (> (count rest) sasl-chunk)
      (recur (subs rest sasl-chunk)
             (conj out (str "AUTHENTICATE " (subs rest 0 sasl-chunk))))
      (cond-> (conj out (str "AUTHENTICATE " rest))
        (= sasl-chunk (count rest)) (conj "AUTHENTICATE +")))))

(defn acked?
  "Whether the server agreed to `cap`, given the set it has acked so far."
  [caps cap]
  (boolean (and caps (contains? caps cap))))

(defn step
  "What to send in answer to `msg`, and what it did to the acked set.

  Returns `{:send [lines] :caps <set>}`. `caps` comes back whether it changed
  or not, so a caller can keep it in whatever it keeps state in — an atom on
  the desktop, a cell on the phone — without this namespace holding any."
  [{:keys [session caps]} msg]
  (let [{:keys [command params]} msg
        caps (or caps #{})
        nothing {:send [] :caps caps}]
    (case (str command)
      "CAP"
      (let [[_ sub offered-str] params
            offered (set (str/split (or offered-str "") #"\s+"))
            wanted (cond-> (filterv offered wanted-caps)
                     (and session (offered "sasl")) (conj "sasl"))]
        (case (str sub)
          "LS" {:caps caps
                :send [(if (seq wanted)
                         (str "CAP REQ :" (str/join " " wanted))
                         "CAP END")]}
          ;; SASL, when acked, ends negotiation itself — CAP END waits for the
          ;; exchange to finish either way.
          "ACK" (let [caps (into caps (remove str/blank?
                                              (str/split (or offered-str "") #"\s+")))]
                  {:caps caps
                   :send [(if (str/includes? (or offered-str "") "sasl")
                            "AUTHENTICATE ATPROTO-CHALLENGE"
                            "CAP END")]})
          "NAK" {:caps caps :send ["CAP END"]}
          nothing))

      ;; The challenge arrives as base64url JSON; the nonce inside it is what
      ;; binds our PDS token to this connection.
      "AUTHENTICATE"
      (let [challenge (first params)]
        (if (and challenge (not= "+" challenge))
          (let [nonce (atproto/json-str (atproto/b64-decode challenge) "nonce")]
            {:caps caps :send (sasl-lines (atproto/sasl-response session nonce))})
          nothing))

      ;; 903 logged in, 904/905/906 did not. A login is also the moment this
      ;; connection can have a signing key: the DID it signs as is only settled
      ;; here. The key is registered at 001 rather than now — MSGSIG is a
      ;; registered-client command, and negotiation has not ended yet.
      "903" (do (when (and (acked? caps "freeq.at/msgsig") (:did session))
                  (msgsig/generate! (:did session)))
                {:caps caps :send ["CAP END"]})

      ("904" "905" "906") {:caps caps :send ["CAP END"]}

      ;; Welcomed. Hand the server the public half, and every reaction from
      ;; here on carries a signature it will take.
      "001" {:caps caps
             :send (if-let [pub (msgsig/public-key)]
                     [(str "MSGSIG " pub)]
                     [])}

      nothing)))
