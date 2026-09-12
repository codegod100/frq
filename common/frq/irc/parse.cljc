(ns frq.irc.parse
  "The IRC wire format, as text. No socket, no host, no platform.

  Split out of `frq.irc` so both compilers can have it: the transport under it
  is a blocking reader thread on the desktop and a `Stream` over
  `SecureSocket` on the phone, and neither of those is this. Everything here
  is a string going in and a map coming out, which is the half of IRC that is
  the same everywhere.

  `frq.irc` still re-exports these under its own name, so callers that say
  `irc/tag-value` — and there are twenty-three of them in `frq.state` and
  `frq.av` — did not have to move."
  (:require [clojure.string :as str]))

(defn parse-line
  "An IRC line into {:tags :prefix :command :params}. The trailing parameter
  (after \" :\") keeps its spaces; everything before it splits on whitespace.

  IRCv3 tags come first when there are any. A connection that negotiates CAP
  gets them where a bare one does not — which is why a client that ignores them
  looks fine as a guest and goes silent once it authenticates."
  [line]
  (let [line (str/trimr line)
        [tags line] (if (str/starts-with? line "@")
                      (let [i (str/index-of line " ")]
                        [(subs line 1 i) (str/triml (subs line i))])
                      [nil line])
        [prefix rest-line] (if (str/starts-with? line ":")
                             (let [i (str/index-of line " ")]
                               [(subs line 1 i) (subs line (inc i))])
                             [nil line])
        i (str/index-of rest-line " :")
        head (if i (subs rest-line 0 i) rest-line)
        trailing (when i (subs rest-line (+ i 2)))
        parts (remove str/blank? (str/split head #" "))]
    {:tags tags
     :account (when tags
                (second (re-find #"(?:^|;)account=([^;]*)" tags)))
     :prefix prefix
     :command (str/upper-case (or (first parts) ""))
     :params (cond-> (vec (rest parts)) trailing (conj trailing))}))

(defn unescape-tag
  "An IRCv3 tag value with its escapes undone.

  `\\:` is a semicolon, `\\s` a space, and `\\\\`, `\\r` and `\\n` themselves —
  the escaping exists because `;` separates tags and a space ends them. It
  matters for any value that can contain either: a reaction tally is
  `emoji:nick;emoji:nick` on the wire and arrives with every one of those
  semicolons written `\\:`, so a reader that skips this step sees one tally
  where there were three, and counts to match."
  [v]
  (when v
    (loop [in (seq v) out []]
      (if-let [c (first in)]
        (if (and (= \\ c) (second in))
          (recur (drop 2 in)
                 (conj out (case (second in)
                             \: \;
                             \s \space
                             \r \return
                             \n \newline
                             (second in))))
          (recur (rest in) (conj out c)))
        (apply str out)))))

(defn escape-tag-value
  "The inverse, for a tag this client sends. An emoji needs none of it; a
  message id could, and the cost of being right is a pass over a short string."
  [v]
  (-> (str v)
      (str/replace "\\" "\\\\")
      (str/replace ";" "\\:")
      (str/replace " " "\\s")
      (str/replace "\r" "\\r")
      (str/replace "\n" "\\n")))

(defn tag-value
  "One IRCv3 tag's value, unescaped, or nil."
  [tags key]
  (when tags
    (some (fn [pair]
            (let [[k v] (str/split pair #"=" 2)]
              (when (= k key) (unescape-tag v))))
          (str/split tags #";"))))

(defn nick-of
  "The nick half of a `nick!user@host` prefix."
  [prefix]
  (when prefix
    (let [i (str/index-of prefix "!")]
      (if i (subs prefix 0 i) prefix))))

