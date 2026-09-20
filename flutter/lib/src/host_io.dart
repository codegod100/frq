/// The two things the renderer and the entry point want from the platform,
/// on a platform that has them.
///
/// Both are small and neither is worth a package. What they have in common is
/// that a browser has neither: there is no environment to read and no file to
/// open, and `dart:io` cannot even be imported there — so the import lives
/// here, behind the conditional in `host.dart`.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

/// An environment variable, or [fallback].
String envOr(String name, String fallback) =>
    Platform.environment[name] ?? fallback;

/// A picture from the filesystem — an attachment the reader picked, before it
/// has been uploaded anywhere.
ImageProvider? localImage(String path) => FileImage(File(path));

/// A picture from the network.
///
/// The plain widget here. The web needs a different one, and the difference
/// is not cosmetic — see `host_web.dart`.
Widget networkImage(String url,
        {BoxFit fit = BoxFit.contain,
        Widget Function()? onError}) =>
    Image.network(url,
        fit: fit,
        errorBuilder: (_, _, _) =>
            onError == null ? const SizedBox.shrink() : onError());

/// The families to ask for when a widget is nothing but an emoji.
///
/// Naming one matters here: a glyph like ✏️ is U+270F plus a variation
/// selector, and DejaVu Sans claims U+270F — so ordinary fallback draws the
/// monochrome pencil and never reaches the colour font.
const List<String> emojiFonts = <String>[
  'Noto Color Emoji',      // Linux, Android
  'Apple Color Emoji',     // macOS, iOS
  'Segoe UI Emoji',        // Windows
];

/// Open a URL in whatever the desktop uses for one.
///
/// `xdg-open` on Linux, which is the only desktop this builds for; the other
/// two are named anyway, because the cost of being wrong about them is a
/// link that silently does nothing and the cost of saying so is one line.
///
/// Best effort and deliberately quiet: a machine with no handler for http is
/// a machine where a link cannot be opened, and that is not worth an error
/// over the conversation.
void openUrl(String url) {
  final cmd = Platform.isMacOS ? 'open' : (Platform.isWindows ? 'start' : 'xdg-open');
  try {
    unawaited(Process.run(cmd, [url]));
  } catch (_) {
    // Nothing to do, and nothing worth saying.
  }
}
