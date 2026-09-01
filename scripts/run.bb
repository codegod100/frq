#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; The app. The native libraries are wherever jolt-native is — a sibling
;; checkout, or the clone `just lib` leaves under .jolt-native.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))

(System/exit
 (:exit @(apply p/process
                {:inherit true
                 :extra-env {"LD_LIBRARY_PATH"
                             (str (fs/path (paths/jolt-native root) "target" "release"))}}
                "jolt" "-M:frq" *command-line-args*)))
