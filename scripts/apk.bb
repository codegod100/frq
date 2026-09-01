#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; The APK, built as a graph.
;;
;;   apk.bb [build|install|run|log]
;;
;; The build itself is android/BUCK; this only asks buck for the file and then
;; does what was asked with it. android/build-apk.bb is the same APK built step
;; by step instead, for when the graph is what is being doubted.
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

(defn apk []
  (->> (paths/out (str (fs/path root "scripts" "buck.bb"))
                  "build" "--show-output" "//:apk")
       str/split-lines
       (some #(when (str/includes? % "frq.apk") (second (str/split % #"\s+"))))
       (str root "/")))

(case action
  "build" (println (apk))
  "install" (p/shell adb "install" "-r" (apk))
  "run" (let [file (apk)]
          (p/shell adb "install" "-r" file)
          (p/shell adb "shell" "am" "force-stop" package)
          (p/shell adb "shell" "am" "start" "-n" (str package "/.FrqActivity")))
  "log" (p/shell adb "logcat" "-s" "VidyaJolt" "Vidya")
  (paths/die "usage: apk.bb [build|install|run|log]"))
