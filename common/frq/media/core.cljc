(ns frq.media.core
  "What both halves agree about a picture in a message: which links are one,
  and what the file behind a link is called.

  The fetching itself is not here and cannot be — jolt pulls a URL down over
  mvn-http and a future, Flutter over `HttpClient` and a Future, and neither
  is a thing `frq.io` can name for the other. What is portable is the part
  that has to agree: two backends that disagreed about which links are
  pictures would show different messages to the same reader."
  (:require [clojure.string :as str]
            [frq.io :as io]))

;; PNG only: it is what both renderers decode, and what freeq's own media
;; endpoint serves. A .jpg link stays a link.
(def image-pattern #"https?://[^\s]+\.png")

(defn image-urls
  "Every image link in a message, in the order they appear."
  [text]
  (vec (distinct (re-seq image-pattern (or text "")))))

(defn- url-hash
  "A stable 32-bit hash of a URL.

  Our own rather than `hash`, because `hash` is the host's: the JVM's and
  Dart's disagree, and a cache name that changes with the compiler is a cache
  that is re-fetched once per backend for no reason. FNV-1a over the UTF-8
  bytes — the seam is asked for those rather than the string walked, because a
  string is a sequence of characters on one host and of code units on the
  other, and the bytes are the one spelling both agree on."
  [s]
  (reduce (fn [h b]
            (-> (bit-xor h b)
                (* 16777619)
                (bit-and 0xFFFFFFFF)))
          2166136261
          (io/utf8-bytes (str s))))

(defn cache-name
  "A filename for a URL: its own last segment behind a hash of the whole
  thing, so two `image.png` from different messages do not collide."
  [url]
  (let [h (url-hash url)
        tail (-> url (str/split #"/") last (str/replace #"[^A-Za-z0-9._-]" ""))]
    (str h "-" (subs tail (max 0 (- (count tail) 40))))))

(defn cached-path
  "Where the picture behind `url` lives, under a directory the caller names."
  [dir url]
  (str dir "/" (cache-name url)))
