(ns frq.metrics
  "How tall a row of chrome is — a button, the compose bar, a line of tabs.

  The reserves the screens count are in points against this: a window's row is
  34 of them, and every gap around it was chosen at that size. A terminal's row
  is one cell, and the same count then reserves two or three times the room the
  strip under the list actually needs — which costs a message a row, and a
  conversation is measured in how many of those fit.

  So the counts stay where the reasoning is and a backend whose rows are a
  different height says so here. `frq.tui` sets `chrome-row` before its first
  paint; a window and a phone leave it alone.

  Shared because the screens that count against it are shared: `below-list` in
  `frq.screens.chats` is the first, and the chat screen's reserves will be next.
  `frq.app` re-defs all three, so `frq.tui` still writes `app/chrome-row`."
  (:require #?@(:cljd []
                :jolt [[glimmer.ratom :refer [atom]]])))

(def window-row 34)
(defonce chrome-row (atom window-row))

(defn chrome-scale [] (/ (double @chrome-row) window-row))

;; Whether the backend under this tree is a terminal, set by `frq.tui` before
;; the first paint and never again. Two things in a message hang on it, and
;; both are about a cell grid rather than a canvas: there is no picture to draw
;; a face with, and a name with nothing to its left is the heading the text
;; hangs off — the shape a terminal has read messages in for forty years.
(defonce terminal? (atom false))

;; And whether that terminal draws pictures over its cells — Kitty's graphics
;; protocol, which kitty, Ghostty and WezTerm answer and an xterm does not.
(defonce terminal-graphics? (atom false))

(defn terminal-face?
  "Whether a message carries a picture of its sender in a terminal.

  Not the same question as `terminal?`: the face is drawn where the protocol
  for one is, and where it is not an `:image` is `[ picture ]` printed beside
  every nick — worse than the nothing that is there now."
  []
  (and @terminal? @terminal-graphics?))
