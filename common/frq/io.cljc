(ns frq.io
  "What the host does, named once so both compilers can answer it.

  `src/` is jolt: jolt.host, jolt.socket, jolt.ffi, a Chez runtime and glimmer
  under the screens. `android/src/` is ClojureDart: dart:io, dart:ffi and
  Flutter. Everything in `common/` is compiled by both, so it cannot mention
  either — a `(:require [jolt.host])` at the top of a namespace is what keeps
  it out of the Android build, not anything about what the code does.

  So this is the seam. Nothing here has an implementation; the backend installs
  one before anything else runs — `frq.io.jolt` on the desktop side,
  `frq.io.dart` on the phone. A namespace under `common/` requires this and
  stays portable.

  The functions are chosen by *intent* rather than by what either platform
  happens to call it. `write-private-file!` rather than a chmod, because Dart
  has no chmod and jolt has no `File.setPermissions`; `local-offset-seconds`
  rather than a zone name, because finding the zone is four platform-specific
  guesses on Linux and one property read on Android. Anywhere the seam names a
  mechanism instead of a result, one of the two sides ends up faking it."
  (:refer-clojure :exclude [slurp spit]))

(defonce ^:private impl
  ;; Keyword → fn. Empty until a backend installs into it, which is a load-time
  ;; effect of requiring `frq.io.jolt` or `frq.io.dart`.
  (atom {}))

(defn install!
  "Register the host's answers. Called once, by the backend, before `-main`
  does anything — see the require list of `frq.app` and of the Flutter entry
  point. Merges, so a backend may install in pieces."
  [m]
  (swap! impl merge m)
  nil)

(defn installed?
  "Whether a backend has answered yet. For the entry points to assert on; the
  wrappers below throw on their own."
  []
  (boolean (seq @impl)))

(defn- call
  [k args]
  (if-let [f (get @impl k)]
    (apply f args)
    (throw (ex-info (str "frq.io: no host installed for " k
                         " — require frq.io.jolt (desktop) or frq.io.dart (android) first")
                    {:op k}))))

;; ------------------------------------------------------------ environment

(defn getenv [n] (call :getenv [n]))

(defn config-dir
  "The directory this client keeps its own files in, already frq-specific.

  Not a rule about XDG: on Android there is no `HOME` and no config directory
  to be relative to, and what the platform hands back is the app's own storage.
  The caller wants somewhere to put `session.edn` and does not care which."
  []
  (call :config-dir []))

;; ------------------------------------------------------------------ files

(defn file-exists? [path] (call :file-exists? [path]))
(defn directory? [path] (call :directory? [path]))
(defn list-dir [path] (call :list-dir [path]))
(defn mkdirs! [path] (call :mkdirs! [path]))
(defn delete-file! [path] (call :delete-file! [path]))

(defn slurp
  "The file as a string, or nil where it cannot be read. Shadows core's, which
  wants a JVM reader."
  [path]
  (call :slurp [path]))

(defn spit
  "Write the string whole. True when it landed."
  [path s]
  (call :spit [path s]))

(defn save-to-downloads!
  "Put a copy of the file at `path` where this reader keeps the things they
  save, under `filename`, and answer with where it landed — or nil.

  Named for the result, like the rest of the seam, because \"where downloads
  go\" is a different question on each of the three targets this has to answer
  on: an XDG directory on a Linux desktop, the shared Download store on
  Android, the app's own storage where neither of those is there. The caller
  has a picture out of the media cache and wants it kept somewhere a file
  manager will find it; which directory that is is the host's business.

  The name is a request rather than a promise: a file already there is not
  overwritten, so what comes back may be `picture-1.png` for a `picture.png`
  that was asked for. Callers show the answer, which is the only honest way to
  say where a thing went."
  [path filename]
  (call :save-to-downloads! [path filename]))

(defn write-private-file!
  "`spit`, for a file nobody else may read — mode 600 where that means
  something. The broker token goes through this and nothing else does."
  [path s]
  (call :write-private-file! [path s]))

;; -------------------------------------------------------------------- text

(defn utf8-bytes
  "A string as a sequence of byte values, 0-255.

  In the seam because there is no portable way to say it: jolt has
  `.getBytes`, which is Java, and ClojureDart has `dart:convert`. `frq.atproto`
  needs it for base64url — SASL is bytes, and a handle with a non-ASCII
  character in it encodes to more of them than it has characters."
  [s]
  (call :utf8-bytes [s]))

(defn utf8-string
  "The inverse: byte values back to the text they spell."
  [bytes]
  (call :utf8-string [bytes]))

;; ------------------------------------------------------------------- time

(defn open-url!
  "Hand `url` to whatever shows web pages here, and say whether that worked.

  Named for the result and not the mechanism, like the rest of this seam: the
  desktop shells out to the portal and the phone asks Android to pick an
  activity, and neither is the other's business. A false answer is not fatal —
  the OAuth screen shows the URL so it can be opened by hand."
  [url]
  (boolean (call :open-url! [url])))

(defn wall-nanos [] (call :wall-nanos []))
(defn mono-nanos [] (call :mono-nanos []))

(defn local-offset-seconds
  "How far the reader's zone is from UTC at `epoch-secs`, DST included.

  An instant rather than a constant: the offset moves twice a year, and a
  backlog read in November carries messages from August."
  [epoch-secs]
  (call :local-offset-seconds [epoch-secs]))

(defn after!
  "Run `f` in about `ms` milliseconds, wherever this host runs UI work.

  Named for when rather than for how, like the rest of this seam. The window
  lends the toolkit's own timer — a callback off the UI thread repaints from
  the wrong one — and the phone has an event loop already and needs no
  lending. What hangs on it is the grace period for crossing from a face to
  the card it raised: see `frq.profile/unhover!`."
  [ms f]
  (call :after! [ms f])
  nil)
