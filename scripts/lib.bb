#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; Both native libraries: libvidya (the tree ABI glimmer-vidya binds) and
;; libjoltmoq (the AV media plane). One workspace, one target directory.
;;
;; A sibling jolt-native checkout wins, so anyone working on the two repos
;; together builds what they are editing; everyone else gets a clone of the
;; gitlab repo under .jolt-native, pinned to the commit deps.edn takes
;; glimmer-vidya from — one place to bump, rather than a second sha here.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def url "https://gitlab.com/nandithebull/jolt-native.git")
(def sha (paths/dep-sha root "https://gitlab.com/nandithebull/jolt-native"))
(def jolt-native (paths/jolt-native root))

;; Already here whenever the sibling checkout exists, since that is what
;; jolt-native then points at.
(when-not (fs/directory? jolt-native)
  (p/shell "git" "clone" url jolt-native)
  (p/shell {:dir jolt-native} "git" "checkout" "--detach" sha))

(p/shell {:dir jolt-native} "just" "build")
