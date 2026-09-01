#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; The app, with the native libraries `just lib` linked into build/lib on the
;; loader path. Those are jolt-native's release, fetched by digest; nothing
;; here looks for a checkout of it.
(require '[babashka.fs :as fs]
         '[babashka.process :as p])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))

(System/exit
 (:exit @(apply p/process
                {:inherit true
                 :extra-env {"LD_LIBRARY_PATH"
                             (str (fs/path root "build" "lib"))}}
                "jolt" "-M:frq" *command-line-args*)))
