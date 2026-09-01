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

;; The checkout this tree belongs to, which in a git worktree is not this tree:
;; the scripts sit under .claude/worktrees/<name>, so "../jolt-native" from
;; here is nothing at all. --git-common-dir is the one thing that answers the
;; same in a worktree as in the checkout it came from.
(defn checkout [root]
  (str (fs/parent (out "git" "-C" (str root)
                       "rev-parse" "--path-format=absolute" "--git-common-dir"))))

;; jolt-native holds both native halves. A sibling checkout wins, so anyone
;; working on the two repos together builds what they are editing; everyone
;; else gets the clone `just lib` leaves under .jolt-native.
(defn jolt-native [root]
  (or (env "JOLT_NATIVE" nil)
      (let [c (checkout root)
            sibling (fs/path (fs/parent c) "jolt-native")]
        (if (fs/directory? sibling)
          (str (fs/canonicalize sibling))
          (str (fs/path c ".jolt-native"))))))

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
