#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; frq's screens in a terminal, from this working tree.
;;
;;   tui.bb [--headless] [--cols=N] [--rows=N]
;;
;; run.bb with the other backend under it. Two things differ, and both are
;; because the terminal backend is not in a jolt-native release yet:
;;
;;   * `libjolttui.so` comes out of a jolt-native checkout's target directory
;;     rather than out of a pinned archive, and is linked into build/lib beside
;;     the two that are pinned. Point JOLT_NATIVE at that checkout, or leave it
;;     beside this one.
;;   * `glimmer-tui` — the jolt half of that backend, and the namespace
;;     `frq.tui` requires — is resolved from the same checkout with -Sdeps,
;;     which is what lets this work from a worktree, where the relative path in
;;     deps.edn's `:tui` alias does not point where it does from a clone. The
;;     alias is not used here for that reason: its coordinate for the same
;;     library wins over the one -Sdeps merges in, so this passes `-m` itself
;;     and leaves `jolt -M:tui` to the checkouts the alias is right for.
;;
;; When the backend ships in a release, both of those become pins like every
;; other, and this script becomes run.bb with a different alias.
(require '[babashka.fs :as fs]
         '[babashka.process :as p])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def lib (fs/path root "build" "lib"))

(def jolt
  (let [pin (fs/path root "scripts" "jolt")]
    (if (and (fs/exists? pin) (fs/which "dotslash")) (str pin) "jolt")))

(defn die [& msg]
  (binding [*out* *err*] (println (apply str msg)))
  (System/exit 1))

;; The checkout the terminal backend lives in. A worktree of it counts — what
;; is wanted is a directory holding `jolt/glimmer-tui` and a built libjolttui.
(def jolt-native
  (let [given (System/getenv "JOLT_NATIVE")
        guess (fs/path root ".." "jolt-native")
        dir (cond
              given (fs/path given)
              (fs/exists? guess) guess
              :else nil)]
    (when-not dir
      (die "no jolt-native checkout: set JOLT_NATIVE, or put one beside this tree"))
    (str (fs/canonicalize dir))))

(def glimmer-tui (fs/path jolt-native "jolt" "glimmer-tui"))

(when-not (fs/exists? glimmer-tui)
  (die glimmer-tui " is not there — this wants the branch that carries the "
       "terminal backend (crates/jolt-tui and jolt/glimmer-tui)"))

;; cargo's release build first, then its debug one, then what buck2 left: any
;; of the three is the library, and which one a person has is their business.
(def jolttui
  (or (first (for [c ["target/release/libjolttui.so"
                      "target/debug/libjolttui.so"]
                   :let [p (fs/path jolt-native c)]
                   :when (fs/exists? p)]
               p))
      (first (sort-by (comp - fs/file-time->millis fs/last-modified-time)
                      (fs/glob (fs/path jolt-native "buck-out")
                               "**/libjolttui.so")))
      (die "no libjolttui.so under " jolt-native
           " — build it: cargo build --release -p jolt-tui")))

;; The two pinned libraries, into build/lib.
(p/shell (str (fs/path root "scripts" "lib.bb")))

;; And the unpinned third, linked rather than copied for the same reason the
;; others are: a rebuild reaches a running tree without anything here going
;; stale.
(let [dest (fs/path lib "libjolttui.so")]
  (fs/create-dirs lib)
  (fs/delete-if-exists dest)
  (fs/create-sym-link dest (str (fs/canonicalize jolttui))))

(System/exit
 (:exit @(apply p/process
                {:inherit true
                 :dir root
                 :extra-env {"LD_LIBRARY_PATH"
                             (str lib (when-let [p (System/getenv "LD_LIBRARY_PATH")]
                                        (str ":" p)))}}
                jolt
                "-Sdeps" (str "{:deps {nandi/glimmer-tui {:local/root \""
                              glimmer-tui "\"}}}")
                "-m" "frq.tui" *command-line-args*)))
