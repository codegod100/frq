#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; buck2, with the machine's paths written where the BUCK files can read them.
;;
;; The same arrangement jolt-native uses, and for the same reason: a BUCK file
;; may not look around the machine, and these answers differ on every one.
;; Generated rather than committed, so no checkout carries another's paths.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def jolt-native (paths/jolt-native root))
(def android-home (paths/env "ANDROID_HOME" (str (fs/path (fs/home) ".local" "share" "android-sdk"))))
(def chez (paths/env "CHEZ_ANDROID" (str (fs/path (fs/home) ".cache" "vidya-chez-android"))))
(def openssl (paths/env "OPENSSL_ANDROID" (str (fs/path (fs/home) ".cache" "frq-openssl-android" "lib"))))

(paths/require-paths! "path"
                      [(fs/path android-home "build-tools" "36.0.0" "aapt2")
                       (fs/path android-home "platforms" "android-36" "android.jar")
                       (fs/path chez "boot" "tarm64le" "scheme.boot")
                       (fs/path openssl "libssl.so")])

;; A jolt-native checkout wins over the pinned release, so that anyone working
;; on both repos at once builds what they are editing. It is staged into this
;; tree because a buck2 cell cannot reach outside its own root, and an action
;; that shelled out to the other project would have nothing to invalidate on.
;; With no checkout the release answers instead, fetched by digest — see
;; toolchains/dist and scripts/libvidya-android.dotslash.
(def libvidya
  (if (fs/directory? (fs/path jolt-native "crates"))
    (let [prebuilt (fs/path root "android" "prebuilt")]
      (p/shell {:dir jolt-native :out :string} "just" "ffi-android")
      (fs/create-dirs (fs/path prebuilt "arm64-v8a"))
      (fs/copy (fs/path jolt-native "build" "android" "arm64-v8a" "libvidya.so")
               (fs/path prebuilt "arm64-v8a" "libvidya.so")
               {:replace-existing true})
      ;; The glue travels with it, for the same reason: editing jolt_main.c
      ;; should relink libjoltapp, and it cannot if buck only knows a path.
      (fs/create-dirs (fs/path prebuilt "glue" "android"))
      (fs/create-dirs (fs/path prebuilt "glue" "include"))
      (fs/copy (fs/path jolt-native "android" "jolt_main.c")
               (fs/path prebuilt "glue" "android" "jolt_main.c")
               {:replace-existing true})
      (doseq [h (fs/glob (fs/path jolt-native "crates" "jolt-vidya" "include") "*.h")]
        (fs/copy h (fs/path prebuilt "glue" "include" (fs/file-name h))
                 {:replace-existing true}))
      "checkout")
    "pinned"))

;; The boot image's other source roots are outside this cell too; hash them
;; here so the digest reaches the action. See android/BUCK.
(def boot-stamp
  (paths/out (str (fs/path root "android" "build-jolt-boot.bb")) "--stamp"))

(spit (str (fs/path root ".buckconfig.local"))
      (str "[frq]\n"
           "  jolt_native = " jolt-native "\n"
           "  android_home = " android-home "\n"
           "  chez_android = " chez "\n"
           "  openssl_android = " openssl "\n"
           "  libvidya = " libvidya "\n"
           "  boot_stamp = " boot-stamp "\n"))

(System/exit
 (:exit @(apply p/process {:inherit true :dir root}
                (str (fs/path root "scripts" "buck2")) *command-line-args*)))
