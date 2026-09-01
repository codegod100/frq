#!/bin/sh
#_(
exec "$(dirname "$0")/../scripts/bb" "$0" "$@"
)

;; frq's Scheme, cross-compiled to an arm64 Chez boot image.
;;
;;   build-jolt-boot.bb OUTPUT_DIRECTORY   build the image
;;   build-jolt-boot.bb --stamp            print what it would be built from
;;
;; The image is built from :paths alone — there is no dependency resolution
;; inside a cross compile — so every source root deps.edn would have resolved
;; is named here instead. Two of them are git dependencies, which means the
;; jolt cache rather than a checkout; the shas come out of deps.edn so there is
;; one place to bump them.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/path (babashka.fs/parent *file*) ".." "scripts")))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[clojure.string :as str])

(def root (str (fs/canonicalize (fs/path (fs/parent *file*) ".."))))
(def args *command-line-args*)
(def stamp-only? (= "--stamp" (first args)))

;; The DotSlash-pinned jolt, not whatever is on PATH: an upstream jolt cannot
;; open a TLS connection on Android — it reads the socket address out of
;; `struct addrinfo` at glibc's offset, which is Bionic's `ai_canonname` — so a
;; build made with one produces an APK that cannot sign in or send a picture.
;; Override with JOLT= to use another.
;;
;; DOTSLASH and JOLT_MANIFEST are set when buck runs this: the manifest and the
;; fetcher are inputs to that action, so the machine running it needs neither
;; jolt nor DotSlash installed, and a remote worker resolves the same pin
;; against the same digest. Without them the shim beside this script answers,
;; which is what a person at a terminal gets.
(def jolt
  (or (paths/env "JOLT" nil)
      (let [dotslash (paths/env "DOTSLASH" nil)
            manifest (paths/env "JOLT_MANIFEST" nil)]
        (if (and dotslash manifest)
          (paths/out dotslash "--" "fetch" manifest)
          (str (fs/path root "scripts" "jolt"))))))

;; The two source roots that are not this repo's, asked of jolt rather than
;; guessed at. `jolt path` prints what it resolved deps.edn to, which is the
;; only thing that knows where a git dependency landed: a plain :git/sha goes
;; to one cache layout and one with :deps/root to another, and glimmer and
;; glimmer-vidya are one of each.
;;
;; GLIMMER and GLIMMER_VIDYA name them instead when a caller already knows.
;; buck sets the second: the jolt cache cannot be an action input, so that
;; build hands over the release archive it fetched by digest, and with both set
;; nothing here shells out at all.
(def roots
  (delay
    ;; From this tree, whatever directory the caller was in: deps.edn is what
    ;; `path` reads.
    (str/split (str/trim (:out (p/shell {:out :string :dir root} jolt "path"))) #":")))

(defn root-of [k env pred]
  (or (paths/env env nil)
      (first (filter pred @roots))
      (paths/die (str "jolt resolved no " (name k) " source root")
                 "check the :deps in deps.edn")))

;; Matched by name rather than by shape: a cache path carries the repo, the sha
;; and — for a dependency with a :deps/root — the root inside it, and which of
;; those it ends with is jolt's business, not this script's.
(defn names? [root s] (str/includes? root s))

(def glimmer-vidya
  (root-of :glimmer-vidya "GLIMMER_VIDYA" #(names? % "glimmer-vidya")))
(def glimmer
  (root-of :glimmer "GLIMMER" #(and (names? % "glimmer")
                                    (not (names? % "glimmer-vidya")))))

(paths/require-paths! "Jolt source root" [glimmer glimmer-vidya])

(def module (paths/env "MODULE" "frq.app"))
(def chez (paths/env "CHEZ_ANDROID" (str (fs/path (fs/home) ".cache" "vidya-chez-android"))))
(def host-scheme (str (fs/path chez "ta6le" "bin" "ta6le" "scheme")))
(def target-boot (fs/path chez "boot" "tarm64le"))
(def xpatch (str (fs/path chez "xc-tarm64le" "s" "xpatch")))

(paths/require-paths! "Android Chez artifact"
                      [host-scheme (fs/path target-boot "petite.boot")
                       (fs/path target-boot "scheme.boot")
                       (fs/path target-boot "scheme.h") xpatch]
                      "Build Chez's tarm64le cross target first.")

(when-not (or (fs/executable? jolt) (fs/which jolt))
  (paths/die (str "Jolt executable not found: " jolt)))

;; The boot image is a pure function of the Scheme sources, the module name,
;; the flat-split flag and Chez's own boot files — all static. Hash them, and
;; skip the whole thing when the stamp still matches: a Rust-only APK rebuild
;; has no reason to spend fifteen single-threaded seconds recompiling Scheme.
;;
;; The flag is part of the stamp on purpose. JOLT_NO_FLAT_SPLIT changes the
;; shape of what `jolt build` emits, so an app.build/ left by an ordinary build
;; is not reusable here; a stamp miss wipes the tree below, which is what the
;; unconditional delete used to be defending against.

;; The hash itself. Every input is hashed here rather than shelled out to
;; sha256sum, so the stamp is one function to read.
(defn sha256 [^bytes bs]
  (->> (.digest (java.security.MessageDigest/getInstance "SHA-256") bs)
       (map #(format "%02x" (bit-and % 0xff)))
       (apply str)))

(defn file-line [f]
  (str (sha256 (fs/read-all-bytes (str f))) "  " f))

(defn stamp []
  (let [sources (->> [(fs/path root "src") glimmer glimmer-vidya]
                     (mapcat #(fs/glob % "**.{jolt,edn}"))
                     (map str)
                     sort)
        lines (concat [module "JOLT_NO_FLAT_SPLIT=1"
                       (try (paths/out jolt "--version") (catch Exception _ ""))]
                      (map file-line sources)
                      (map file-line [(fs/path target-boot "petite.boot")
                                      (fs/path target-boot "scheme.boot")
                                      xpatch]))]
    (sha256 (.getBytes (str/join "\n" lines) "UTF-8"))))

;; buck needs this before the work rather than after: the sources it hashes
;; live in the jolt cache and in jolt-native, outside this cell, so nothing
;; else makes them reach an action's digest. See the `buck` recipe in the
;; justfile.
(when stamp-only?
  (println (stamp))
  (System/exit 0))

(def out-dir (or (first args)
                 (paths/die "usage: build-jolt-boot.bb OUTPUT_DIRECTORY | --stamp")))
(def stamp-file (fs/path out-dir "jolt.boot.stamp"))
(def want (stamp))

(when (and (fs/exists? (fs/path out-dir "jolt.boot"))
           (fs/exists? (fs/path out-dir "scheme.h"))
           (fs/exists? stamp-file)
           (= want (str/trim (slurp (str stamp-file)))))
  (binding [*out* *err*] (println "jolt boot image up to date"))
  (System/exit 0))

(fs/delete-if-exists stamp-file)
(fs/delete-tree (fs/path out-dir "project"))
(fs/delete-tree (fs/path out-dir "cross"))
(fs/create-dirs (fs/path out-dir "project"))
(fs/create-dirs (fs/path out-dir "cross"))
(spit (str (fs/path out-dir "project" "deps.edn"))
      (str "{:paths [\"" (fs/path root "src") "\" \"" glimmer "\" \"" glimmer-vidya "\"]}\n"))

(p/shell {:dir (str (fs/path out-dir "project"))
          :extra-env {"JOLT_NO_FLAT_SPLIT" "1"}}
         jolt "build" "-m" module "-o" "app")

(spit (str (fs/path out-dir "cross" "compile.ss"))
      (str "(import (chezscheme))\n"
           "(load \"" xpatch "\")\n"
           "(optimize-level 2)\n"
           "(generate-inspector-information #f)\n"
           "(compile-file \"" (fs/path out-dir "project" "app.build" "flat.ss") "\""
           " \"" (fs/path out-dir "cross" "flat.so") "\")\n"
           "(make-boot-file \"" (fs/path out-dir "jolt.boot") "\" '()\n"
           "  \"" (fs/path target-boot "petite.boot") "\"\n"
           "  \"" (fs/path target-boot "scheme.boot") "\"\n"
           "  \"" (fs/path out-dir "cross" "flat.so") "\")\n"))

(p/shell {:extra-env {"SCHEMEHEAPDIRS" (str (fs/path chez "ta6le" "boot" "ta6le"))}}
         host-scheme "--script" (str (fs/path out-dir "cross" "compile.ss")))

(fs/copy (fs/path target-boot "scheme.h") (fs/path out-dir "scheme.h")
         {:replace-existing true})

;; Last, so an interrupted build leaves no stamp and the next run redoes it.
(spit (str stamp-file) (str want "\n"))
