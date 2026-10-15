# nimkit, vendored

nimkit is the widget toolkit in
[`nandi-conda/webby`](https://github.com/nandi-conda/webby)'s `framework/src`,
copied here at commit `31482f9cec6cfdd2962a66dfd00efa7dc3e79c9a`. It is a copy
rather than a dependency because frq needed things the toolkit did not have,
and webby is not ours to change. The Android backend was left behind: there is
no APK.

What frq added, so a later copy from upstream knows what to carry across:

* `picture`, a widget showing a picture by URL or by bytes, fitted to a box
  or cropped round. GTK fetches and decodes it once per URL and draws it with
  cairo; the web makes it an `<img>`.
* `wrapping`, a row that wraps its items onto as many lines as they need — a
  `GtkFlowBox` on GTK, `flex-wrap` on the web.
* `caret` / `caret=`, the insertion point of an entry, in code points.
* `reveal`, which scrolls the nearest scroll until a widget is in view.
* `onFollow` on a scroll that follows its end, told when the reader leaves
  the end and when they come back to it.
* `onWindowSize`, the window's size whenever it changes.
* On GTK, `resizeUp` after a child is added or removed. GTK caches whether a
  container trades height for width, and a container that answered "no"
  before a wrapping row arrived below it kept answering "no" — so the row
  was laid out as tall as it would be one item to a line.
* On the web, layout rules that make a column behave as a GTK box does: its
  fixed children keep their size, its expanding ones start from their
  content, a column in a row fills the row's height, and a box with no
  padding of its own leaves a class's padding standing.
