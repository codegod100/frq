#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; Both native libraries, out of jolt-native's release rather than a checkout.
;;
;; libvidya is the tree ABI glimmer-vidya binds; libjoltmoq is the AV media
;; plane. They come out of one archive because they are built together, and
;; they land in build/lib because a loader wants one directory. `just run` does
;; not come through here — running a change to jolt-native means building it,
;; which is what the dev shell is for — so this is the released half: the same
;; bytes the APK takes through nix/android.nix, and what a run of the last
;; release takes.
;;
;; Nothing is compiled here. The pinned bytes are the bytes: this repo used to
;; clone jolt-native and cargo-build it, which meant a Rust toolchain, a build
;; whose output depended on the machine, and two places — the clone's sha and
;; the release digest — that could disagree about which jolt-native frq was
;; running against. Bump scripts/*.dotslash instead: see bump-jolt-native.bb.
;;
;; Linked rather than copied, so a bump reaches a running tree by relinking and
;; nothing goes stale in build/ — except for the one object that has to be
;; repaired on the way through. See below.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[clojure.string :as str])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def lib (fs/path root "build" "lib"))

;; v0.1.3's desktop libjoltmoq.so has 68 undefined `snd_*` symbols and no
;; DT_NEEDED on libasound: cpal's ALSA host is compiled in, and the library it
;; calls is not named. It is the defect that release fixed for Android, in the
;; place the fix did not reach — buck2 keeps a build script's cfgs and drops
;; its link directives, so `cargo:rustc-link-lib=asound` never became a link
;; argument. Undefined symbols are legal in a cdylib, so nothing said so until
;; something tried to load it.
;;
;; So the library is named here instead, on a copy: the DotSlash cache holds
;; what the release published, and rewriting that in place would make a
;; verified digest a lie about the bytes on disk.
;;
;; This goes away with the release that links it. `patchelf --print-needed`
;; below is the test for that — a fixed object is linked, not copied.
(def repairs {"libjoltmoq.so" "libasound.so.2"})

(defn needed [file]
  (set (str/split-lines (paths/out "patchelf" "--print-needed" file))))

(fs/create-dirs lib)
(doseq [name ["libvidya-linux" "libjoltmoq-linux"]]
  (let [file (paths/dist root name)
        base (fs/file-name file)
        dest (fs/path lib base)
        missing (get repairs base)]
    (fs/delete-if-exists dest)
    (if (and missing (not (contains? (needed file) missing)))
      (do (fs/copy file dest)
          ;; Out of the cache read-only, and patchelf writes.
          (fs/set-posix-file-permissions dest "rw-r--r--")
          (paths/out "patchelf" "--add-needed" missing (str dest))
          (println (str (fs/relativize root dest) " <- " file " (+" missing ")")))
      (do (fs/create-sym-link dest file)
          (println (str (fs/relativize root dest) " -> " file))))))
