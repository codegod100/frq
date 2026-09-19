# The Flutter half

The renderer, and the window it runs in. Everything else is Nim.

```
lib/main.dart          the entry point: reads FRQ_AUTOCONNECT, then runs the app
lib/nim_renderer.dart  the widget tree from Nim, as Flutter widgets
lib/nim_theme.dart     the design tokens
test/nim_layout_test.dart  every screen laid out for real, at three sizes
```

## What the renderer knows

The tag vocabulary, and nothing else — no screens, no state, no idea what
"connect" means. Nim decides what the screen is; this decides what a `vbox`
looks like. The measure of whether the split is honest is how boring this file
is: if a feature ever needs a change here AND in Nim, the boundary is in the
wrong place.

Three rules in it are worth knowing before changing any of it, because each
cost a screenful of `Cannot hit test a render box that has never been laid
out` to find:

* **`Expanded` only inside a Flex.** The renderer threads the axis it is
  building into, because Flutter offers no way to ask after the fact. An
  `Expanded` in a `Wrap` fails the layout, and every box under it is then
  hit-tested having never been laid out.
* **A paragraph is one `RichText`, not a row of words.** Children of a `Wrap`
  are given unbounded width, so a long URL can never wrap — it overflows and
  takes the screen with it.
* **`expand` is stated by the node that expands.** A row that fills the
  remaining height stretches on its cross axis, and stretch needs a bounded
  height to stretch to.

`test/nim_layout_test.dart` is what enforces all three. It renders every screen
at phone, desktop and a deliberately cramped size, headless, and fails on
anything that reaches `FlutterError` — which is where a layout error goes
instead of to the caller, so a test that only pumps and asserts on widgets
passes while the screen is in pieces.

## Building

```bash
just build desktop   # the debug bundle
just run desktop     # and open it
just test layout     # the widget tests, headless
```

`just` builds `libfrqcore.so` first: the app dlopens it at startup, and a
missing one is a blank window with a `StateError` behind it. The core resolves
OpenSSL through dynlib at run time, which is why the recipe puts the host's
library on the loader path.

## What used to be here

`src/`, 5,500 lines of ClojureDart: the screens, the host implementations, and
a `frq.hiccup` that did what `nim_renderer.dart` does now. It compiled to
three targets — Android, Linux and the web — and both of the others went with
it. A browser has no `dart:ffi`, so the web needs the Nim core built to wasm
rather than ClojureDart brought back; Android needs `libfrqcore.so` for its
ABIs, which is a build problem rather than a design one.

The `android/` and `web/` directories are still here and still describe real
targets. Nothing builds them today.
