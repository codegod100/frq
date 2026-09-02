;; Where the other halves of this build are, and how to ask a program a
;; question without writing the same three lines of shell each time.
;;
;; Every script here loads this; nothing else does.
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
;; Only the desktop libraries are pinned this way now — `just lib`, and the
;; release half of a run. The Android side is nix/android.nix, which fetches
;; the same archives by the same digests as `fetchurl`.
;;
;; DOTSLASH names the fetcher for a caller that has one but has not got it on
;; PATH.
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

;; A nix command, as an argv to run where nix is.
;;
;; nix is not on every host this runs on: on the machine these scripts were
;; written for it lives in an Arch distrobox, at the same path — which is why
;; the container is entered rather than the tree copied into it. See CLAUDE.md.
;; Trailing arguments are passed through `"$@"` rather than pasted into the
;; command line, so a value with a space in it survives the shell in between.
(defn nix [root args & [trailing]]
  (if (fs/which "nix")
    (concat args trailing)
    (concat ["distrobox" "enter" "arch" "--" "bash" "-lc"
             (str "cd " root " && exec " (str/join " " args) " \"$@\"")
             "--"]
            trailing)))
