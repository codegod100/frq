(ns frq.actions
  "What a screen can ask the app to do, named once so both can answer.

  The same shape as `frq.io`, one layer up: the cells in `frq.cells` are state
  a shared screen can read directly, and these are the things it cannot do for
  itself. `connect!` on the desktop is `frq.state/connect!` — IRC over jolt's
  TLS, SASL, the reader thread — and on the phone it is the dart:io one. The
  screen calls the same name either way and knows neither."
  (:refer-clojure :exclude [name]))

(defonce ^:private impl (atom {}))

(defn install!
  "Register what this platform does. Anything left out is a no-op, so a screen
  can be rendered before the action behind a button exists — which is how the
  phone got the connect screen on it before SASL was ported."
  [m]
  (swap! impl merge m)
  nil)

(defn- call [k args]
  (when-let [f (get @impl k)] (apply f args)))

(defn connect! [] (call :connect! []))
(defn disconnect! [] (call :disconnect! []))
(defn forget-session! [] (call :forget-session! []))
(defn open-url! [url] (call :open-url! [url]))
