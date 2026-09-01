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
(def android-home (paths/env "ANDROID_HOME" (str (fs/path (fs/home) ".local" "share" "android-sdk"))))
(def chez (paths/env "CHEZ_ANDROID" (str (fs/path (fs/home) ".cache" "vidya-chez-android"))))
(def openssl (paths/env "OPENSSL_ANDROID" (str (fs/path (fs/home) ".cache" "frq-openssl-android" "lib"))))

(paths/require-paths! "path"
                      [(fs/path android-home "build-tools" "36.0.0" "aapt2")
                       (fs/path android-home "platforms" "android-36" "android.jar")
                       (fs/path chez "boot" "tarm64le" "scheme.boot")
                       (fs/path openssl "libssl.so")])

;; The boot image is compiled from source roots outside this cell — glimmer and
;; glimmer-vidya, out of the jolt cache — which cannot be action inputs. Hash
;; them here so the digest reaches the action instead. See android/BUCK.
(def boot-stamp
  (paths/out (str (fs/path root "android" "build-jolt-boot.bb")) "--stamp"))

(spit (str (fs/path root ".buckconfig.local"))
      (str "[frq]\n"
           "  android_home = " android-home "\n"
           "  chez_android = " chez "\n"
           "  openssl_android = " openssl "\n"
           "  boot_stamp = " boot-stamp "\n"))

(System/exit
 (:exit @(apply p/process {:inherit true :dir root}
                (str (fs/path root "scripts" "buck2")) *command-line-args*)))
