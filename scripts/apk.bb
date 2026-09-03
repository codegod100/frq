#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; The APK, out of the flake.
;;
;;   apk.bb [build|install|run|log]
;;
;; The build itself is nix/android.nix, reached as `.#apk`; this only asks nix
;; for the file and then does what was asked with it. Nothing here names an
;; Android SDK, an NDK, a Chez cross target or an OpenSSL: the derivation
;; builds or fetches every one of them, which is the difference between this
;; and the buck2 graph it replaces — that one was handed four hand-built paths
;; from the machine and stopped if any was missing.
;;
;; The APK is signed with a debug key generated inside the derivation, so the
;; output is installable and not reproducible; anything meant for a store gets
;; signed from `.#apk-unsigned` instead. See nix/android.nix.
;;
;; FRQ_NIX_STORE builds the whole graph somewhere else rather than here —
;;
;;     FRQ_NIX_STORE=ssh-ng://eu.nixbuild.net scripts/apk.bb
;;
;; which is the shape android.nix asks for: with a `builders` entry instead,
;; nix copies every remotely-built output back, and androidenv's NDK is both
;; `preferLocalBuild` and absent from cache.nixos.org, so 3.1 GB of toolchain
;; is built here and uploaded. With the remote as the *store* only .drv files
;; go up. An install then needs the file here, so it is fetched back at the
;; end — one APK rather than the closure that made it.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def action (or (first *command-line-args*) "build"))
(def adb (paths/env "ADB" (str (fs/path (fs/home) ".local" "share" "android-sdk"
                                        "platform-tools" "adb"))))
(def package "uk.nandi.frq")

;; --eval-store auto goes with a remote store and only with one: evaluation
;; wants this tree, which is here.
(def store
  (when-let [s (paths/env "FRQ_NIX_STORE" nil)]
    ["--store" s "--eval-store" "auto"]))

;; Built without a `result` symlink: the path is what the caller wants, and a
;; symlink into a store that may not be this one is not a useful thing to leave
;; in the tree.
(defn build []
  (let [out (->> (paths/nix root (concat ["nix" "build" (str root "#apk")
                                          "--no-link" "--print-out-paths"]
                                         store))
                 (apply paths/out)
                 str/split-lines
                 (filter #(str/starts-with? % "/nix/store/"))
                 last)]
    (when-not out
      (paths/die "nix build printed no store path"))
    out))

;; Off a remote store the path names a file on the builder, so adb has nothing
;; to open. `nix copy --no-check-sigs --from` brings just that one path here.
(defn local-file []
  (let [out (build)]
    (when store
      (apply p/shell (paths/nix root (concat ["nix" "copy" "--no-check-sigs"
                                              "--from" (paths/env "FRQ_NIX_STORE" nil)
                                              out]))))
    out))

(case action
  "build" (println (build))
  "install" (p/shell adb "install" "-r" (local-file))
  "run" (let [file (local-file)]
          (p/shell adb "install" "-r" file)
          (p/shell adb "shell" "am" "force-stop" package)
          (p/shell adb "shell" "am" "start" "-n" (str package "/.FrqActivity")))
  "log" (p/shell adb "logcat" "-s" "VidyaJolt" "Vidya")
  (paths/die "usage: apk.bb [build|install|run|log]"))
