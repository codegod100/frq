(ns frq.crypto
  "The four primitives `frq.msgsig` needs, named once.

  Ed25519 and SHA-256 are the only things in this client that a platform
  cannot hand over as data: on the desktop they are OpenSSL's, reached through
  the same libcrypto jolt already loads for TLS, and on a phone there is no
  libcrypto to reach — Android ships none a process may link — so the Dart
  side brings its own.

  Deliberately narrow. Everything else about a signature — what gets signed,
  how it is written down, which key id names it — is the same everywhere and
  lives in `frq.msgsig`. This is the part that is arithmetic somebody else
  should be doing.

  A platform that installs nothing signs nothing, and `generate!` answers nil.
  That is a real state and the client already knows it: a reaction from an
  unsigned connection is one only this client can see, which is what the
  namespace's own docstring says about libcrypto refusing to play."
  (:refer-clojure :exclude [rand]))

(defonce ^:private impl (atom {}))

(defn install! [m] (swap! impl merge m) nil)

(defn- call [k args]
  (when-let [f (get @impl k)] (apply f args)))

(defn random-bytes
  "`n` bytes from the platform's own source of them, or nil."
  [n]
  (call :random-bytes [n]))

(defn sha256
  "The digest of a byte sequence, as bytes."
  [bs]
  (call :sha256 [bs]))

(defn ed25519-generate!
  "Mint a key from a 32-byte seed and keep it. Returns the public half as
  bytes, or nil where there is no Ed25519 to be had.

  The seed is passed in rather than made here: for Ed25519 the seed *is* the
  key, and which bytes those are is `frq.msgsig`'s business."
  [seed]
  (call :ed25519-generate! [seed]))

(defn ed25519-sign
  "Sign bytes with the kept key. Returns the signature as bytes, or nil."
  [bs]
  (call :ed25519-sign [bs]))

(defn ed25519-forget!
  "Drop the key. Called when the connection goes, so a reconnect signs with a
  key the server has actually been told about."
  []
  (call :ed25519-forget! []))
