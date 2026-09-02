#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; The app, from this working tree.
;;
;;   run.bb [args...]
;;
;; Everything but the source is pinned: jolt comes from scripts/jolt.dotslash
;; and the two native libraries from scripts/lib*.dotslash, fetched by digest
;; and linked into build/lib, which is the one directory the loader is pointed
;; at. `just lib` is done here rather than asked for — the pins say what those
;; bytes are, so there is nothing for a person to decide before running.
;;
;; Deliberately not `nix run .#frq`. That builds the flake's own copy of the
;; source, which is the tree as git has it — so an edit that has not been
;; committed, or has been committed on a branch the command was not pointed at,
;; runs as whatever was there before, silently. A run that is meant to answer
;; "does my change work" has to be the files on disk.
(require '[babashka.fs :as fs]
         '[babashka.process :as p])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def lib (str (fs/path root "build" "lib")))

;; The pinned jolt — scripts/jolt is a DotSlash script, so running it is
;; fetching it. Off linux-x86_64 the pin has no asset and the fallback is
;; whatever `jolt` is on PATH, which is what that manifest says to do.
(def jolt
  (let [pin (fs/path root "scripts" "jolt")]
    (if (and (fs/exists? pin) (fs/which "dotslash")) (str pin) "jolt")))

(p/shell (str (fs/path root "scripts" "lib.bb")))

(System/exit
 (:exit @(apply p/process
                {:inherit true
                 :dir root
                 :extra-env {"LD_LIBRARY_PATH"
                             (str lib (when-let [p (System/getenv "LD_LIBRARY_PATH")]
                                        (str ":" p)))}}
                jolt "-M:frq" *command-line-args*)))
