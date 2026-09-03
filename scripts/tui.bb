#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; frq's screens in a terminal, from this working tree.
;;
;;   tui.bb [--headless] [--demo] [--cols=N] [--rows=N] [--wait=MS] [--dump]
;;
;; run.bb with the other backend under it, and the same two halves: the frq
;; source is the files on disk, and everything below it is the flake's. The
;; dev shell builds jolt-native and names both Jolt sides of it — glimmer-vidya
;; for the window, glimmer-tui for the terminal — so this needs no checkout
;; beside the tree and no library fetched by digest.
;;
;; It still loads libvidya as well as libjolttui. `frq.app` requires
;; glimmer-vidya, and `frq.tui` requires glimmer-tui after it so the backend
;; installed last is the terminal; the window's library is resolved and then
;; asked for nothing.
;;
;; No nixGL here, unlike run.bb: a terminal wants nothing from the host's GL
;; driver, which is the reason this output exists on machines that have none.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def self (str (fs/path root "scripts" "tui.bb")))

;; Outside the shell, get inside it and come back to this same script — the
;; test, the flag and the reasoning are run.bb's.
(when-not (System/getenv "JOLT_NATIVE_LIB")
  (let [cmd (paths/nix root
                       ["nix" "develop" root
                        "--max-jobs" (paths/env "FRQ_MAX_JOBS" "0")
                        "--command" self]
                       *command-line-args*)]
    (System/exit (:exit @(apply p/process {:inherit true :dir root} cmd)))))

(def overrides
  (str "{:deps {jolt-lang/glimmer {:local/root \"" (System/getenv "GLIMMER_SRC") "\"}"
       " nandi/glimmer-vidya {:local/root \"" (System/getenv "GLIMMER_VIDYA_SRC") "\"}"
       " nandi/glimmer-tui {:local/root \"" (System/getenv "GLIMMER_TUI_SRC") "\"}}}"))

(System/exit
 (:exit @(apply p/process
                {:inherit true
                 :dir root
                 :extra-env {"LD_LIBRARY_PATH"
                             (->> [(System/getenv "JOLT_NATIVE_LIB")
                                   (System/getenv "LD_LIBRARY_PATH")]
                                  (remove str/blank?)
                                  (str/join ":"))}}
                (concat ["jolt" "-Sdeps" overrides "-m" "frq.tui"]
                        *command-line-args*))))
