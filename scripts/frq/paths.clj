;; Where the other halves of this build are, and how to ask a program a
;; question without writing the same three lines of shell each time.
;;
;; Every script here loads this; nothing else does. The answers match the
;; justfile's, deliberately — a person who runs `just apk` and a person who
;; runs android/build-apk.bb should be building the same thing.
(ns frq.paths
  (:require [babashka.fs :as fs]
            [babashka.process :as p]
            [clojure.edn :as edn]
            [clojure.string :as str]))

(defn die [& lines]
  (binding [*out* *err*] (run! println lines))
  (System/exit 1))

(defn out
  "Run a command and return its standard output, trimmed. Throws if it fails."
  [& args]
  (str/trim (:out (apply p/shell {:out :string} (map str args)))))

(defn env [k default] (or (not-empty (System/getenv k)) default))

;; An archive pinned in scripts/*.dotslash, resolved to the file its manifest
;; names. DotSlash downloads it once, verifies the digest and caches it, so
;; every script here asks the same question of the same pin and a second
;; jolt-native checkout is never part of the answer.
;;
;; DOTSLASH names the fetcher for a caller that has one but has not got it on
;; PATH — buck sets it, because the fetcher is an input to those actions.
(defn dist [root name]
  (let [manifest (fs/path root "scripts" (str name ".dotslash"))]
    (when-not (fs/exists? manifest)
      (die (str "no DotSlash manifest: " manifest)))
    (out (env "DOTSLASH" "dotslash") "--" "fetch" manifest)))

;; The sha deps.edn pins for a git url, so a bump there reaches the boot image.
;; Read as data rather than grepped: it is Clojure, and so is this.
(defn dep-sha [root url]
  (->> (:deps (edn/read-string (slurp (str (fs/path root "deps.edn")))))
       vals
       (some #(when (= url (:git/url %)) (:git/sha %)))))

(defn require-paths!
  "Every path must exist, or say which one did not and stop."
  [label paths & hint]
  (doseq [p paths]
    (when-not (fs/exists? (str p))
      (apply die (str "missing " label ": " p) hint))))
