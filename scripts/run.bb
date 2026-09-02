#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; The app.
;;
;;   run.bb [args...]
;;
;; `nix run .#frq`, which is the whole build: the native libraries, the jolt
;; runtime, the dependency graph, and a launcher that puts nixGL in front off
;; NixOS so the window opens. Nothing here needs `just lib` first.
;;
;; Nix is not on every host that has this checkout — on the developer's it
;; lives in the Arch distrobox — so a host without it is not an error, it is
;; the same command run one layer in. The worktree path is the same inside the
;; container as outside, which is what lets the `cd` be this path verbatim.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def box (paths/env "FRQ_DISTROBOX" "arch"))

(defn quote-arg
  "One argument, safe for a shell that will read the whole line as a string."
  [s]
  (str "'" (str/replace (str s) "'" "'\\''") "'"))

;; `--` and then the args: everything past it is the app's, not nix's.
(def nix-args
  (concat ["nix" "run" ".#frq"]
          (when (seq *command-line-args*) (cons "--" *command-line-args*))))

(def command
  (if (fs/which "nix")
    (cons {:dir root} nix-args)
    (do
      (when-not (fs/which "distrobox")
        (paths/die "no nix and no distrobox — install nix, or set FRQ_DISTROBOX"
                   "to a container that has it."))
      [{} "distrobox" "enter" box "--"
       "bash" "-lc" (str "cd " (quote-arg root) " && "
                         (str/join " " (map quote-arg nix-args)))])))

(System/exit
 (:exit @(apply p/process (assoc (first command) :inherit true)
                (rest command))))
