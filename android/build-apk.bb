#!/bin/sh
#_(
exec "$(dirname "$0")/../scripts/bb" "$0" "$@"
)

;; Glue the two halves of the frq Android app into an APK.
;;
;;   libvidya.so    the C ABI on Rust/egui, out of the pinned release, and the
;;                  NativeActivity's own library (it holds android-activity's
;;                  glue, so it owns the event loop)
;;   libjoltmoq.so  the AV media plane — MoQ over QUIC, Opus, H.264, Camera2
;;   libjoltapp.so  jolt-native's android/jolt_main.c plus frq's Jolt boot
;;                  image, dlopened by the above
;;   libc++_shared.so  the NDK's C++ runtime, which libjoltmoq names
;;   classes.dex    two Java classes: a picture chooser answers through
;;                  onActivityResult and a NativeActivity has nowhere to
;;                  deliver that, and Camera2 has no C API worth the name
;;   libssl.so      OpenSSL, because the platform's own is not ours to load: an
;;   libcrypto.so   app's linker namespace refuses /system/lib64/libssl.so, and
;;                  without one there is no TLS at all on the phone
;;
;; Neither half is built here beyond that last link: the UI library and the glue
;; come out of jolt-native's release, fetched by digest through the DotSlash
;; pins in scripts/, and the boot image from build-jolt-boot.bb. Both native
;; pieces are jolt-native's — only the boot image is frq's.
;;
;;   build-apk.bb [build|install|run|log]
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/path (babashka.fs/parent *file*) ".." "scripts")))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def action (or (first *command-line-args*) "build"))

(def android-home (paths/env "ANDROID_HOME" (str (fs/path (fs/home) ".local" "share" "android-sdk"))))
(def ndk-home (paths/env "ANDROID_NDK_HOME" (str (fs/path (fs/home) ".local" "share" "android-ndk-r29"))))
(def chez (paths/env "CHEZ_ANDROID" (str (fs/path (fs/home) ".cache" "vidya-chez-android"))))
(def openssl (paths/env "OPENSSL_ANDROID" (str (fs/path (fs/home) ".cache" "frq-openssl-android" "lib"))))
(def build (fs/path root "android" "build"))
(def jolt-build (fs/path build "jolt"))
(def stage (fs/path build "stage"))
(def tools (fs/path android-home "build-tools" "36.0.0"))
(def android-jar (fs/path android-home "platforms" "android-36" "android.jar"))
(def adb (paths/env "ADB" (str (fs/path android-home "platform-tools" "adb"))))
(def ndk-bin (fs/path ndk-home "toolchains" "llvm" "prebuilt" "linux-x86_64" "bin"))
(def package "uk.nandi.frq")
(def activity (str package "/.FrqActivity"))
(def api "28")
(def clang (str (fs/path ndk-bin (str "aarch64-linux-android" api "-clang"))))
(def arm-lib (fs/path stage "lib" "arm64-v8a"))

(paths/require-paths! "Android tool"
                      [clang android-jar
                       (fs/path tools "aapt2") (fs/path tools "zipalign")
                       (fs/path tools "apksigner") (fs/path tools "d8")
                       (fs/path openssl "libssl.so") (fs/path openssl "libcrypto.so")])

;; --- the UI half -----------------------------------------------------------
;; The release's own object, and the glue beside it, both by digest: this build
;; compiles no Rust and needs no jolt-native checkout, exactly as the graph in
;; android/BUCK needs none.
(def vidya-so (paths/dist root "libvidya-android"))
;; The media plane, out of the same archive. The glue registers its symbols and
;; includes its header, so this is not optional beside that jolt_main.c: link
;; without it and --no-undefined says so.
(def joltmoq-so (paths/dist root "libjoltmoq-android"))
(def glue-c (paths/dist root "android-glue"))
(def glue-include (fs/path (fs/parent (fs/parent glue-c)) "include"))
(paths/require-paths! "library" [vidya-so joltmoq-so glue-c glue-include])

;; --- the Jolt half ---------------------------------------------------------
(p/shell (str (fs/path root "android" "build-jolt-boot.bb")) (str jolt-build))
;; The boot image travels as a blob in the object file's data section; the
;; _binary_jolt_boot_{start,end} symbols jolt_main.c reads come from this.
(p/shell {:dir (str jolt-build)}
         (str (fs/path ndk-bin "llvm-objcopy"))
         "--input-target=binary"
         "--output-target=elf64-littleaarch64"
         "--binary-architecture=aarch64"
         "jolt.boot" "jolt_boot.o")

;; --- the Java half ---------------------------------------------------------
;; Two classes: the photo chooser's result has to land somewhere and native
;; code is not somewhere, and Camera2 has no C API worth the name. d8 turns
;; them into the classes.dex the runtime loads.
(def java-build (fs/path build "java"))
(fs/delete-tree java-build)
(fs/create-dirs (fs/path java-build "classes"))
;; android.jar on the class path is where every android.* type comes from; the
;; JDK's own java.* is what is left, and neither class uses anything of it that
;; Android does not have. (`-bootclasspath` would be the stricter way to say
;; that, and javac refuses it for a release this recent.)
;;
;; Every class under android/java, the way android/BUCK globs them: naming one
;; here left CameraCapture out of the dex, and libjoltmoq looks that class up
;; by name over JNI the moment a call starts the camera.
(apply p/shell "javac" "--release" "17"
       "--class-path" (str android-jar)
       "-d" (str (fs/path java-build "classes"))
       (map str (fs/glob (fs/path root "android" "java") "**.java")))
(apply p/shell (str (fs/path tools "d8")) "--min-api" api "--output" (str java-build)
       (map str (fs/glob (fs/path java-build "classes") "**.class")))

(fs/delete-tree stage)
(fs/create-dirs arm-lib)
(fs/copy (fs/path java-build "classes.dex") (fs/path stage "classes.dex"))
(fs/copy vidya-so (fs/path arm-lib "libvidya.so"))
(fs/copy joltmoq-so (fs/path arm-lib "libjoltmoq.so"))
;; openh264 is C++ and asks to be linked against libc++_shared.so by name, so
;; libjoltmoq carries it as a DT_NEEDED and the APK has to carry the object —
;; an app's linker namespace will not hand out the platform's own.
(fs/copy (fs/path ndk-bin ".." "sysroot" "usr" "lib" "aarch64-linux-android"
                  "libc++_shared.so")
         (fs/path arm-lib "libc++_shared.so"))
;; jolt.mvn-http dlopens these by name at first use; beside the app's own
;; libraries is where an app's namespace will answer for that name.
(doseq [lib ["libssl.so" "libcrypto.so"]]
  (fs/copy (fs/path openssl lib) (fs/path arm-lib lib)))

(p/shell clang "-shared" "-fPIC" "-O2"
         "-o" (str (fs/path arm-lib "libjoltapp.so"))
         (str glue-c)
         (str (fs/path jolt-build "jolt_boot.o"))
         (str "-I" jolt-build)
         (str "-I" glue-include)
         (str "-L" arm-lib)
         (str (fs/path chez "tarm64le" "boot" "tarm64le" "libkernel.a"))
         (str (fs/path chez "lz4" "lib" "liblz4.a"))
         "-lvidya" "-ljoltmoq" "-landroid" "-llog" "-lz" "-ldl" "-lm"
         "-Wl,--no-undefined")

;; --- the APK ---------------------------------------------------------------
(def unaligned (fs/path build "frq-unaligned.apk"))
(def aligned (fs/path build "frq-aligned.apk"))
(def apk (fs/path build "frq.apk"))
(run! fs/delete-if-exists [unaligned aligned apk])
(p/shell (str (fs/path tools "aapt2")) "link"
         "-o" (str unaligned)
         "-I" (str android-jar)
         "--manifest" (str (fs/path root "android" "AndroidManifest.xml"))
         "--min-sdk-version" api
         "--target-sdk-version" "36"
         "--version-code" "1"
         "--version-name" "0.1.0")
;; Stored, not deflated: the loader maps these straight out of the APK.
(p/shell {:dir (str stage)} "zip" "-q" "-0" (str unaligned)
         "lib/arm64-v8a/libvidya.so" "lib/arm64-v8a/libjoltmoq.so"
         "lib/arm64-v8a/libc++_shared.so" "lib/arm64-v8a/libjoltapp.so"
         "lib/arm64-v8a/libssl.so" "lib/arm64-v8a/libcrypto.so")
;; The dex is read by the runtime rather than mapped, so it may as well deflate.
(p/shell {:dir (str stage)} "zip" "-q" (str unaligned) "classes.dex")
(p/shell (str (fs/path tools "zipalign")) "-f" "-p" "4" (str unaligned) (str aligned))

(def keystore (fs/path (fs/home) ".android" "debug.keystore"))
(when-not (fs/exists? keystore)
  (fs/create-dirs (fs/parent keystore))
  (p/shell "keytool" "-genkeypair" "-v"
           "-keystore" (str keystore) "-storepass" "android" "-keypass" "android"
           "-alias" "androiddebugkey" "-keyalg" "RSA" "-keysize" "2048"
           "-validity" "10000"
           "-dname" "CN=Android Debug,O=Android,C=US"))
(p/shell (str (fs/path tools "apksigner")) "sign"
         "--ks" (str keystore) "--ks-key-alias" "androiddebugkey"
         "--ks-pass" "pass:android" "--key-pass" "pass:android"
         "--out" (str apk) (str aligned))
(p/shell {:out :string} (str (fs/path tools "apksigner")) "verify" (str apk))

(case action
  "build" (println (str apk))
  "install" (p/shell adb "install" "-r" (str apk))
  "run" (do (p/shell adb "install" "-r" (str apk))
            (p/shell adb "shell" "am" "force-stop" package)
            (p/shell adb "shell" "am" "start" "-n" activity))
  "log" (p/shell adb "logcat" "-s" "VidyaJolt" "Vidya")
  (paths/die "usage: build-apk.bb [build|install|run|log]"))
