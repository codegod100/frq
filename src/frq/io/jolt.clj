(ns frq.io.jolt
  "The desktop's answers to `frq.io`, over jolt.host.

  Requiring this installs them — there is no init to call, because the point of
  the seam is that `frq.store` and `frq.clock` under `common/` never mention a
  backend. Every desktop entry point requires this before `frq.app`."
  (:require [clojure.string :as str]
            [frq.io :as io]
            [frq.platform :as platform]
            [jolt.host :as host]))

(def ^:private zone
  ;; TZ if it is set, otherwise whatever /etc/localtime points at, otherwise
  ;; UTC — which is wrong by hours but never wrong by a day's worth of parsing.
  ;;
  ;; /etc/localtime is not always a symlink. In a container it is often the
  ;; bytes themselves — distrobox's Arch has it as an overlay-mounted regular
  ;; file — and then `readlink -f` answers with the path it was given and there
  ;; is no zone name to read out of it at all. That fell through to UTC, so a
  ;; channel read seven hours ahead of the clock on the same screen.
  ;;
  ;; The colon form is what libc has for exactly this: `TZ=:/etc/localtime`
  ;; names the tzfile by path rather than by zone, and tzset reads it with the
  ;; transitions intact — the offset it gives is DST-correct per instant, not a
  ;; fixed one. Nothing downstream cares that this is a path: the zone is only
  ;; ever handed to tz-offset-seconds, never shown.
  ;;
  ;; The `getprop` branch is Android's, and it stays here rather than moving to
  ;; `frq.io.dart`: this is the code the APK runs today, and it runs it through
  ;; jolt. When the Flutter APK is the only APK, this branch is dead and goes.
  (delay
    (or (let [tz (host/getenv "TZ")] (when (seq tz) tz))
        (try
          (second (re-find #"/zoneinfo/(.+)$"
                           (str/trim (str (host/sh-out "readlink -f /etc/localtime")))))
          (catch Exception _ nil))
        (when (host/file-exists? "/etc/localtime") ":/etc/localtime")
        (try
          (let [tz (str/trim (str (host/sh-out "getprop persist.sys.timezone")))]
            (when (seq tz) tz))
          (catch Exception _ nil))
        "UTC")))

(defn- config-dir []
  (let [xdg (host/getenv "XDG_CONFIG_HOME")
        home (host/getenv "HOME")]
    (str (if (seq xdg) xdg (str home "/.config")) "/frq")))

(defn- slurp* [path]
  (try (slurp path) (catch Exception _ nil)))

(defn- spit* [path s]
  (try (spit path s) true (catch Exception _ false)))

(defn- write-private-file!
  "Created before it is written, so the token is never on disk world-readable
  even for an instant."
  [path s]
  (try
    (host/sh (str "install -m 600 /dev/null '" path "'"))
    (spit path s)
    (host/sh (str "chmod 600 '" path "'"))
    true
    (catch Exception _ false)))

(io/install!
 {:getenv               host/getenv
  :open-url!            platform/open-url!
  :config-dir           config-dir
  :file-exists?         host/file-exists?
  :directory?           host/directory?
  :list-dir             host/list-dir
  :mkdirs!              host/mkdirs!
  :delete-file!         host/delete-file!
  :slurp                slurp*
  :spit                 spit*
  :write-private-file!  write-private-file!
  :utf8-bytes           (fn [s] (mapv #(bit-and (int %) 0xff) (.getBytes (str s))))
  :utf8-string          (fn [bs] (String. (byte-array (map unchecked-byte bs))))
  :wall-nanos           host/wall-nanos
  :mono-nanos           host/mono-nanos
  :local-offset-seconds (fn [secs] (host/tz-offset-seconds @zone secs))
  ;; The window's own timer and not a thread that sleeps: a callback that
  ;; repaints has to arrive on the thread the toolkit draws from, and
  ;; `frq.platform` is where each backend lends this one its loop.
  :after!               platform/after!})
