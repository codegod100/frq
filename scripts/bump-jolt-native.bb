#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; Move every jolt-native pin in this tree to a release of it.
;;
;;     scripts/bump-jolt-native.bb            # the latest release
;;     scripts/bump-jolt-native.bb v0.1.3     # a named one
;;
;; A jolt-native bump is three facts in two places: the URL and the digest of
;; each Android archive in nix/android.nix, and the release's commit in
;; deps.edn. Done by hand it is a lot of copying between a browser and a
;; sha256sum, and the failure mode is a pin that still says v0.1.2 while its
;; digest is v0.1.3's — which fetchurl catches at build time and no sooner.
;;
;; Only the APK fetches a release now; a desktop run builds jolt-native out of
;; the flake input, whose rev is flake.lock's. So the two halves this moves are
;; the phone's bytes and the Jolt source that binds them, and the thing to
;; remember is that flake.lock is a third pin nothing here touches — see the
;; jolt-native input's comment in flake.nix for why it runs ahead.
;;
;; So: ask GitLab what the release holds, fetch each archive once, weigh it,
;; write nix/android.nix back, and put the release's commit in deps.edn — which
;; is what jolt resolves glimmer-vidya from, and so what the boot image
;; compiles against.
;;
;; Nothing here decides whether the new release is a good idea. It only makes
;; the tree say one version instead of two.
(require '[babashka.classpath :as cp])
(cp/add-classpath (str (babashka.fs/parent *file*)))
(require '[frq.paths :as paths]
         '[babashka.fs :as fs]
         '[babashka.process :as p]
         '[cheshire.core :as json]
         '[clojure.string :as str])

(def root (str (fs/parent (fs/parent (fs/canonicalize *file*)))))
(def project "nandithebull%2Fjolt-native")
(def repo "https://gitlab.com/nandithebull/jolt-native")

;; The release, as GitLab has it. `?per_page=1` when no tag is asked for: the
;; list is newest first, and the newest is what "latest" means here — the
;; /releases/permalink/latest endpoint sorts by release date, which is not the
;; same thing once a release is edited.
(defn release [tag]
  (let [url (if tag
              (str "https://gitlab.com/api/v4/projects/" project "/releases/" tag)
              (str "https://gitlab.com/api/v4/projects/" project "/releases?per_page=1"))
        body (json/parse-string (paths/out "curl" "-fsSL" url))]
    (if tag
      body
      (or (first body) (paths/die (str "no releases at all under " repo))))))

;; The archive an entry names, at the new tag. The URL a pin carries is the
;; release permalink — /-/releases/<tag>/downloads/<asset> — so the asset's name
;; is its last segment, and the name carries the version too. Both move.
(defn retag [url old new]
  (-> url
      (str/replace (str "/releases/" old "/") (str "/releases/" new "/"))
      (str/replace (str "-" old ".") (str "-" new "."))))

(defn tag-of [url]
  (second (re-find #"/-/releases/([^/]+)/downloads/" url)))

;; Fetch once per distinct URL, then weigh it: the digest is over the archive as
;; downloaded, which is what fetchurl hashes too — not of anything inside it.
(def weigh
  (memoize
   (fn [dir url]
     (let [file (fs/path dir (last (str/split url #"/")))]
       (println (str "  fetching " (fs/file-name file)))
       (p/shell "curl" "-fsSL" "-o" (str file) url)
       (first (str/split (paths/out "sha256sum" (str file)) #"\s+"))))))

;; nix/android.nix fetches the release archives as `pkgs.fetchurl`, which is the
;; only fetch of a release left in this tree. Rewritten as text for the same
;; reason deps.edn is — the file is mostly the comments explaining each step,
;; and there is no round-tripping Nix as data here anyway.
;;
;; Every fetchurl whose url points at the repo, whatever it is called: a third
;; archive appearing in android.nix should move with the other two rather than
;; be remembered about.
(defn bump-nix! [tmp tag]
  (let [file (fs/path root "nix" "android.nix")
        text (slurp (str file))
        ;; url and sha256 as one match, so the pair moves together. Anything
        ;; between them — a comment, another attribute — would not match, and
        ;; not matching is the safe direction: it leaves the pin alone and says
        ;; nothing was written.
        pattern (re-pattern (str "(url\\s*=\\s*\")(" (java.util.regex.Pattern/quote repo)
                                 "[^\"]*)(\";\\s*\n\\s*sha256\\s*=\\s*\")([^\"]*)(\")"))
        seen (atom [])
        updated (str/replace text pattern
                             (fn [[_ head url mid _ tail]]
                               (let [new-url (retag url (tag-of url) tag)
                                     digest (weigh tmp new-url)]
                                 (swap! seen conj (last (str/split new-url #"/")))
                                 (str head new-url mid digest tail))))]
    (when (empty? @seen)
      (paths/die (str "no fetchurl in " file " points at " repo)))
    (spit (str file) updated)
    (doseq [name @seen] (println (str "  nix/android.nix " name)))))

;; deps.edn takes glimmer-vidya as a git dependency, and the boot image is
;; compiled from the source root jolt resolves that to. Replaced as text rather
;; than round-tripped as EDN: the file is mostly comments explaining why each
;; pin is where it is, and rewriting it as data would throw all of them away.
(defn bump-deps! [commit]
  (let [file (fs/path root "deps.edn")
        text (slurp (str file))
        old (paths/dep-sha root repo)]
    (cond
      (nil? old) (paths/die (str "no dependency on " repo " in deps.edn"))
      (= old commit) (println "  deps.edn already at this commit")
      :else (do (spit (str file) (str/replace text old commit))
                (println (str "  deps.edn " (subs old 0 8) " -> " (subs commit 0 8)))))))

(let [tag (first *command-line-args*)
      rel (release tag)
      tag (get rel "tag_name")
      commit (get-in rel ["commit" "id"])
      tmp (fs/create-temp-dir {:prefix "jolt-native-"})]
  (println (str "jolt-native " tag " (" (subs commit 0 8) ")"))
  (try
    (bump-nix! tmp tag)
    (finally (fs/delete-tree tmp)))
  (bump-deps! commit)
  (println (str "\nNow: git diff, then `just apk` — the pins are "
                "written, nothing is built.")))
