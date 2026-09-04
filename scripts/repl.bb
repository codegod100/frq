#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; A jolt against this tree, with the native libraries under it.
;;
;;   repl.bb                  a REPL
;;   repl.bb nrepl-server     the same thing for an editor to connect to
;;   repl.bb -e '(+ 1 1)'     or any other jolt command line
;;
;; This exists because `jolt` in the repo root does not work on its own.
;; deps.edn carries :jolt/native, so every jolt invocation here — a REPL, an
;; nREPL server, `jolt -M:frq` — loads libvidya and libjoltmoq before it reads
;; a line, and dies naming the library if the loader cannot find them. The
;; libraries are the flake's, which means an LD_LIBRARY_PATH nobody should have
;; to remember.
;;
;; So it is run.bb without the app: the same re-exec into `nix develop`, the
;; same deps overrides for the Jolt halves that bind those objects, and then
;; whatever jolt command line the caller asked for. run.bb is `repl.bb -M:frq`
;; with a window's worth of extra care about the GL driver; this is the rest of
;; the time.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def self (str (fs/path root "scripts" "repl.bb")))

;; Outside the shell, get inside it and come back — the test, the flag and the
;; reasoning are run.bb's.
(when-not (System/getenv "JOLT_NATIVE_LIB")
  (let [cmd (paths/nix root
                       ["nix" "develop" root
                        "--max-jobs" (paths/env "FRQ_MAX_JOBS" "0")
                        "--command" self]
                       *command-line-args*)]
    (System/exit (:exit @(apply p/process {:inherit true :dir root} cmd)))))

;; The Jolt halves that have to match those objects, for run.bb's reason: the
;; pin in deps.edn is a release, and what the shell built is the flake input.
(def overrides
  (str "{:deps {jolt-lang/glimmer {:local/root \"" (System/getenv "GLIMMER_SRC") "\"}"
       " nandi/glimmer-vidya {:local/root \"" (System/getenv "GLIMMER_VIDYA_SRC") "\"}}}"))

(System/exit
 (:exit @(apply p/process
                {:inherit true
                 :dir root
                 :extra-env {"LD_LIBRARY_PATH"
                             (->> [(System/getenv "JOLT_NATIVE_LIB")
                                   (System/getenv "FRQ_LIB_PATH")
                                   (System/getenv "LD_LIBRARY_PATH")]
                                  (remove str/blank?)
                                  (str/join ":"))}}
                (concat ["jolt" "-Sdeps" overrides] *command-line-args*))))
