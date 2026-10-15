## frq's look, as style sheets for nimkit's two backends.
##
## The renderer gives every widget style classes and names no colour; this
## says what the classes look like. nimkit passes a class `x` through as
## `nk-x` on both platforms (and as plain `x` too on GTK), so the selectors
## below are the same names in both sheets.
##
## The palette is the one the Flutter build painted with — frq's own dark
## one, and flatkit's light one — kept as numbers here because they are the
## app's identity rather than the toolkit's.

import std/strutils

type Palette* = object
  background*, surface*, hover*, pressed*, border*, text*, textDim*,
    accent*, accentHover*, onAccent*, danger*, onDanger*, success*: string

const
  frqDark* = Palette(
    background: "#202833", surface: "#2C3440", hover: "#343C48",
    pressed: "#48505A", border: "#3B4450", text: "#CCD1D7",
    textDim: "rgba(204, 209, 215, 0.6)", accent: "#F4E3CF",
    accentHover: "#F8ECDE", onAccent: "#000000", danger: "#FDA1A0",
    onDanger: "#000000", success: "#92CF9C")
  frqLight* = Palette(
    background: "#F6F6F7", surface: "#FFFFFF", hover: "#EDEDEF",
    pressed: "#DEDEE2", border: "#DADADE", text: "#1E1E22",
    textDim: "#66666E", accent: "#3584E4", accentHover: "#2A76D3",
    onAccent: "#FFFFFF", danger: "#D12D3A", onDanger: "#FFFFFF",
    success: "#26A269")

proc fill(sheet: string, c: Palette): string =
  sheet.multiReplace(
    ("$background", c.background), ("$surface", c.surface),
    ("$hover", c.hover), ("$pressed", c.pressed), ("$border", c.border),
    ("$textDim", c.textDim), ("$text", c.text),
    ("$accentHover", c.accentHover), ("$accent", c.accent),
    ("$onAccent", c.onAccent), ("$danger", c.danger),
    ("$onDanger", c.onDanger), ("$success", c.success))

const gtkSheet = """
window, window.background { background-color: $background; color: $text; }
label { color: $text; }
label selection { background-color: $accent; color: $onAccent; }
*:link, label link { color: $accent; }
scrollbar { background-color: transparent; border: none; }
scrollbar slider { background-color: $border; min-width: 6px; min-height: 6px; border: none; }
separator { background-color: $border; min-height: 1px; min-width: 1px; }
flowboxchild { padding: 0; }

button {
  background-image: none; background-color: $surface; color: $text;
  border: 1px solid $border; border-radius: 6px; box-shadow: none;
  text-shadow: none; -gtk-icon-shadow: none; padding: 4px 12px; min-height: 22px;
}
button label { color: $text; }
button:hover { background-color: $hover; }
button:active, button:checked { background-color: $pressed; }
button:focus { border-color: $accent; }
button.suggested-action { background-color: $accent; border-color: $accent; }
button.suggested-action label { color: $onAccent; font-weight: 600; }
button.suggested-action:hover { background-color: $accentHover; }
button.destructive-action { background-color: $danger; border-color: $danger; }
button.destructive-action label { color: $onDanger; font-weight: 600; }

button.nk-compact { padding: 2px 8px; min-height: 18px; }
button.nk-compact label { font-size: 13px; font-weight: 600; }
button.nk-compact.nk-on { background-color: $accent; border-color: $accent; }
button.nk-compact.nk-on label { color: $onAccent; }

button.nk-plain { background-color: transparent; border-color: transparent; padding: 0 2px; min-height: 0; }
button.nk-plain:hover { background-color: $hover; }

button.nk-pill { background-color: $hover; border: none; border-radius: 6px; padding: 1px 6px; min-height: 0; }
button.nk-pill:hover { background-color: $pressed; }
button.nk-pill.nk-mine { background-color: $accent; }
button.nk-pill.nk-mine label { color: $onAccent; }

button.nk-face { padding: 0; min-height: 0; min-width: 0; border-radius: 999px; border: none; background-color: $hover; }
button.nk-emoji-button { background-color: transparent; border: none; padding: 0 2px; }

entry {
  background-image: none; background-color: $surface; color: $text;
  border: 1px solid $border; border-radius: 6px; box-shadow: none;
  padding: 4px 8px; min-height: 22px; caret-color: $accent;
}
entry:focus { border: 2px solid $accent; padding: 3px 7px; }
entry placeholder, entry text placeholder { color: $textDim; }
entry selection { background-color: $accent; color: $onAccent; }

check { background-image: none; background-color: $surface; border: 1px solid $border; border-radius: 4px; }
check:checked { background-color: $accent; border-color: $accent; color: $onAccent; }
checkbutton label { color: $text; }

.nk-card { background-color: $surface; border: 1px solid $border; border-radius: 6px; padding: 12px; }
button.nk-card { background-color: $surface; padding: 12px; }
button.nk-card:hover { background-color: $hover; }
.nk-card.nk-task { background-color: $hover; border-left: 3px solid $accent; }
.nk-ground { background-color: $background; }
.nk-dialog { background-color: $surface; border: 1px solid $border; border-radius: 10px; padding: 20px; }

.nk-task-card { background-color: $surface; border: 1px solid $border; border-left: 3px solid $textDim; border-radius: 6px; }
.nk-task-card.nk-tone-new { border-color: $accent; }
.nk-task-card.nk-tone-active { border-color: $text; }
.nk-task-card.nk-tone-success { border-color: $success; }
.nk-task-card.nk-tone-danger { border-color: $danger; }
.nk-task-card.nk-highlight { background-color: $hover; }
.nk-task-head { padding: 8px 12px; border-bottom: 1px solid $border; }
.nk-task-body { padding: 12px; }
.nk-headline { font-weight: 700; font-size: 12px; }
.nk-headline.nk-tone-new { color: $accent; }
.nk-headline.nk-tone-success { color: $success; }
.nk-headline.nk-tone-danger { color: $danger; }

.nk-title { font-size: 24px; font-weight: bold; }
.nk-title2 { font-size: 20px; font-weight: 600; }
.nk-dim { color: $textDim; opacity: 1; }
.nk-caption { font-size: 12px; }
.nk-tiny { font-size: 10px; }
.nk-mono, .nk-code { font-family: monospace; }
.nk-code { color: $accent; font-size: 12px; }
.nk-error { color: $danger; }
.nk-dot { font-size: 10px; }
.nk-dot.nk-live { color: $success; }
.nk-dot.nk-off { color: $textDim; }
"""

const webSheet = """
html, body { background: $background; color: $text; font: 14px/1.35 system-ui, sans-serif; }
.nk-root { background: $background; }
.nk-label { color: $text; overflow-wrap: anywhere; }
.nk-label a { color: $accent; }
.nk-label ::selection { background: $accent; color: $onAccent; }
.nk-separator { background: $border; }
.nk-scroll { scrollbar-color: $border transparent; scrollbar-width: thin; }

button {
  font: inherit; background: $surface; color: $text; border: 1px solid $border;
  border-radius: 6px; padding: 5px 12px; cursor: pointer; white-space: nowrap;
}
button:hover { background: $hover; }
button:active { background: $pressed; }
button:focus-visible { outline: 2px solid $accent; outline-offset: -1px; }
button.nk-suggested { background: $accent; color: $onAccent; border: 1px solid $accent; border-radius: 6px;
  padding: 5px 12px; font-weight: 600; }
button.nk-suggested:hover { background: $accentHover; }
button.nk-destructive { background: $danger; color: $onDanger; border: 1px solid $danger; border-radius: 6px;
  padding: 5px 12px; font-weight: 600; }

button.nk-compact { padding: 3px 8px; font-size: 13px; font-weight: 600; }
button.nk-compact.nk-on { background: $accent; color: $onAccent; border-color: $accent; }

.nk-item.nk-plain { padding: 0 2px; border-radius: 4px; min-width: 0; }
.nk-item.nk-plain > .nk-label { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.nk-item.nk-plain:hover { background: $hover; }

button.nk-pill { background: $hover; border: none; padding: 1px 6px; font-size: 14px; }
button.nk-pill:hover { background: $pressed; }
button.nk-pill.nk-mine { background: $accent; color: $onAccent; }

button.nk-face { padding: 0; border-radius: 50%; border: none; background: $hover; }
img.nk-face { cursor: default; }
img.nk-face.nk-click { cursor: pointer; }
button.nk-emoji-button { background: none; border: none; padding: 0 2px; }

input[type=text], input[type=password] {
  font: inherit; background: $surface; color: $text; border: 1px solid $border;
  border-radius: 6px; padding: 6px 8px; outline: none; caret-color: $accent; box-sizing: border-box;
}
input[type=text]:focus, input[type=password]:focus { border-color: $accent; box-shadow: 0 0 0 1px $accent; }
input::placeholder { color: $textDim; }
input[type=checkbox] { accent-color: $accent; }

.nk-card { background: $surface; border: 1px solid $border; border-radius: 6px; padding: 12px; }
.nk-item.nk-card { display: flex; padding: 12px; border-radius: 6px; }
.nk-item.nk-card:hover { background: $hover; }
.nk-card.nk-task { background: $hover; border-left: 3px solid $accent; }
.nk-ground { background: $background; }
.nk-dialog { background: $surface; border: 1px solid $border; border-radius: 10px; padding: 20px;
  box-shadow: 0 8px 24px rgba(0,0,0,0.4); }

.nk-task-card { background: $surface; border: 1px solid $border; border-left: 3px solid $textDim;
  border-radius: 6px; overflow: hidden; }
.nk-task-card.nk-tone-new { border-color: $accent; }
.nk-task-card.nk-tone-active { border-color: $text; }
.nk-task-card.nk-tone-success { border-color: $success; }
.nk-task-card.nk-tone-danger { border-color: $danger; }
.nk-task-card.nk-highlight { background: $hover; }
.nk-task-head { padding: 8px 12px; border-bottom: 1px solid $border; }
.nk-task-body { padding: 12px; }
.nk-headline { font-weight: 700; font-size: 12px; }
.nk-headline.nk-tone-new { color: $accent; }
.nk-headline.nk-tone-success { color: $success; }
.nk-headline.nk-tone-danger { color: $danger; }

.nk-title { font-size: 24px; font-weight: bold; }
.nk-title2 { font-size: 20px; font-weight: 600; }
.nk-dim { color: $textDim; opacity: 1; }
.nk-caption { font-size: 12px; }
.nk-tiny { font-size: 10px; }
.nk-mono, .nk-code { font-family: ui-monospace, monospace; }
.nk-code { color: $accent; font-size: 12px; white-space: pre-wrap; max-height: 160px; overflow: auto; }
.nk-error { color: $danger; }
.nk-dot { font-size: 10px; }
.nk-dot.nk-live { color: $success; }
.nk-dot.nk-off { color: $textDim; }
.nk-emoji, .nk-pill, .nk-emoji-button { font-family: "Noto Color Emoji", "Apple Color Emoji", "Segoe UI Emoji", system-ui, sans-serif; }
"""

proc gtkCss*(c: Palette): string = gtkSheet.fill(c)

proc webCss*(): string =
  ## Both palettes, the browser choosing between them by the reader's
  ## setting. The light one is the default and the dark one the override, so
  ## a browser that cannot say gets the kit's light look.
  webSheet.fill(frqLight) & "\n@media (prefers-color-scheme: dark) {\n" &
    webSheet.fill(frqDark) & "\n}\n"
