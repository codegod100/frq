#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; The app, from this working tree.
;;
;;   run.bb [args...]
;;
;; Two halves, and the split is the point. The frq source is the files on disk,
;; uncommitted edits and all. Everything under it — jolt, glimmer,
;; glimmer-vidya, both native objects — is the flake's, built rather than
;; fetched: this re-execs itself inside `nix develop`, and that shell is the
;; jolt-native input compiled and the Jolt halves that bind it, at the revs
;; flake.lock names.
;;
;; Deliberately not `nix run .#frq`. That builds the flake's own copy of the
;; source, which is the tree as git has it — so an edit that has not been
;; committed, or has been committed on a branch the command was not pointed at,
;; runs as whatever was there before, silently. A run that is meant to answer
;; "does my change work" has to be the files on disk.
;;
;; And deliberately not the scripts/*.dotslash pins either, which is what this
;; used to do. Those name a release; a change to jolt-native is by definition
;; not in one yet. `just lib` still fetches them — the APK and the buck2 build
;; take the released bytes — but a run does not.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def self (str (fs/path root "scripts" "run.bb")))

;; Outside the shell, get inside it and come back to this same script. The
;; shell is what sets JOLT_NATIVE_LIB, so its absence is the test — no flag to
;; forget, and `nix develop --command scripts/run.bb` by hand is not a second
;; code path.
;;
;; --max-jobs 0 is what sends the work to the `builders` entry rather than
;; compiling it here. Left to the default, nix prefers the local machine, and a
;; cold jolt-native is egui, openh264 and quinn on a laptop — for a derivation
;; a remote builder has likely built already. FRQ_MAX_JOBS is the way out on a
;; machine with no builder configured: FRQ_MAX_JOBS=auto.
(when-not (System/getenv "JOLT_NATIVE_LIB")
  (let [args ["nix" "develop" root "--max-jobs" (paths/env "FRQ_MAX_JOBS" "0")
              "--command" self]
        ;; nix is not on every host this runs on: on the machine this was
        ;; written for it lives in an Arch distrobox, at the same path — which
        ;; is why the container is entered rather than the tree copied into it.
        ;; See CLAUDE.md.
        cmd (if (fs/which "nix")
              (concat args *command-line-args*)
              (concat ["distrobox" "enter" "arch" "--" "bash" "-lc"
                       (str "cd " root " && exec " (str/join " " args) " \"$@\"")
                       "--"]
                      *command-line-args*))]
    (System/exit (:exit @(apply p/process {:inherit true :dir root} cmd)))))

;; The Jolt halves that have to match those objects. glimmer-vidya lives inside
;; jolt-native and binds libvidya's ABI, so it comes out of the same input that
;; was built rather than deps.edn's git sha — the pin drifting from the library
;; is exactly what the flake input's comment describes. glimmer is the flake's
;; for the same reason.
(def overrides
  (str "{:deps {jolt-lang/glimmer {:local/root \"" (System/getenv "GLIMMER_SRC") "\"}"
       " nandi/glimmer-vidya {:local/root \"" (System/getenv "GLIMMER_VIDYA_SRC") "\"}}}"))

;; On NixOS the store's Mesa is the system's and the window opens. Anywhere
;; else — a bare host, or the distrobox above — the real driver is the host's,
;; so defer to nixGL, which prepends it. Same rule the flake's launcher uses.
(def runner
  (when-not (fs/exists? "/run/current-system")
    (some-> (System/getenv "NIXGL") not-empty vector)))

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
                (concat runner ["jolt" "-Sdeps" overrides "-M:frq"] *command-line-args*))))
