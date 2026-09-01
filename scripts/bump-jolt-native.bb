#!/bin/sh
#_(
exec "$(dirname "$0")/bb" "$0" "$@"
)

;; Move every jolt-native pin in this tree to a release of it.
;;
;;     scripts/bump-jolt-native.bb            # the latest release
;;     scripts/bump-jolt-native.bb v0.1.3     # a named one
;;
;; A jolt-native bump is four facts in three places: the tag, the URL, the size
;; and the digest of each archive in scripts/*.dotslash, the release's commit in
;; deps.edn, and the table buck reads, which is generated from the first. Done
;; by hand it is a lot of copying between a browser and a sha256sum, and the
;; failure mode is a manifest that still says v0.1.2 while its digest is v0.1.3's
;; — which DotSlash catches, but only on the machine that next fetches it.
;;
;; So: ask GitLab what the release holds, fetch each archive once, weigh it,
;; write the manifests back, put the release's commit in deps.edn — which is
;; what jolt resolves glimmer-vidya from, and so what the boot image compiles
;; against — and re-run dotslash-to-buck.
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

(def here (fs/parent (fs/canonicalize *file*)))
(def root (str (fs/parent here)))
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

;; The manifests this tree pins out of jolt-native. Every DotSlash file beside
;; this script whose providers point at the repo — rather than a list written
;; here, which would be a sixth place to forget.
(defn manifests []
  (->> (fs/glob here "*.dotslash")
       sort
       (keep (fn [file]
               (let [text (slurp (str file))
                     json (json/parse-string (subs text (str/index-of text "{")))]
                 (when (->> (get json "platforms")
                            vals
                            (some #(str/starts-with? (get-in % ["providers" 0 "url"]) repo)))
                   {:file file :text text :json json}))))))

;; The archive an entry names, at the new tag. The URL a manifest carries is the
;; release permalink — /-/releases/<tag>/downloads/<asset> — so the asset's name
;; is its last segment, and the name carries the version too. Both move.
(defn retag [url old new]
  (-> url
      (str/replace (str "/releases/" old "/") (str "/releases/" new "/"))
      (str/replace (str "-" old ".") (str "-" new "."))))

(defn tag-of [url]
  (second (re-find #"/-/releases/([^/]+)/downloads/" url)))

;; Fetch once per distinct URL, then weigh it: DotSlash wants the size and the
;; sha256 of the archive as downloaded, not of anything inside it.
(def weigh
  (memoize
   (fn [dir url]
     (let [file (fs/path dir (last (str/split url #"/")))]
       (println (str "  fetching " (fs/file-name file)))
       (p/shell "curl" "-fsSL" "-o" (str file) url)
       {:size (fs/size file)
        :digest (first (str/split (paths/out "sha256sum" (str file)) #"\s+"))
        :file file}))))

;; What the shim will reach for inside the archive. A release that moved a file
;; leaves a manifest that fetches and verifies and then cannot resolve, which is
;; a worse thing to find out from than this.
(defn check-path! [{:keys [file]} path]
  (let [names (set (str/split-lines (paths/out "tar" "-tzf" (str file))))]
    (when-not (some #(= path (str/replace % #"^\./" "")) names)
      (paths/die (str "no " path " in " (fs/file-name file))
                 "The release moved it; the manifest's `path` needs a hand."))))

;; The JSON back out, in the shape it went in: two-space indentation, a value
;; after each key, and the `//` comment block above it kept — that block is why
;; anyone reading the manifest knows what the object is for.
(def pretty
  (json/create-pretty-printer
   (assoc json/default-pretty-print-options
          :indentation "  "
          :indent-arrays? true
          :object-field-value-separator ": ")))

(defn rewrite [{:keys [file text json]} tmp tag]
  (let [platforms (get json "platforms")
        updated
        (into (array-map)
              (for [[platform entry] platforms
                    :let [url (retag (get-in entry ["providers" 0 "url"]) (tag-of (get-in entry ["providers" 0 "url"])) tag)
                          {:keys [size digest] :as got} (weigh tmp url)]]
                (do
                  (check-path! got (get entry "path"))
                  [platform (-> entry
                                (assoc "size" size "digest" digest)
                                (assoc-in ["providers" 0 "url"] url))])))
        head (subs text 0 (str/index-of text "{"))
        ;; The prose above the JSON names the release too — "from jolt-native's
        ;; v0.1.3 release". Left saying the old one it would be a lie the moment
        ;; this script succeeds.
        head (reduce (fn [h old] (str/replace h old tag))
                     head
                     (distinct (keep #(tag-of (get-in % ["providers" 0 "url"])) (vals platforms))))]
    (spit (str file) (str head (json/generate-string (assoc json "platforms" updated) {:pretty pretty}) "\n"))
    (println (str "  " (fs/file-name file)))))

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
      files (manifests)
      tmp (fs/create-temp-dir {:prefix "jolt-native-"})]
  (when (empty? files)
    (paths/die (str "no DotSlash manifest in " here " points at " repo)))
  (println (str "jolt-native " tag " (" (subs commit 0 8) ")"))
  (try
    (doseq [m files] (rewrite m tmp tag))
    (finally (fs/delete-tree tmp)))
  (bump-deps! commit)
  (p/shell (str (fs/path here "dotslash-to-buck")))
  (println (str "\nNow: git diff, then `just lib` and `just apk` — the pins are "
                "written, nothing is built.")))
