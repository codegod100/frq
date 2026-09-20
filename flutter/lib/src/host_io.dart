/// The two things the renderer and the entry point want from the platform,
/// on a platform that has them.
///
/// Both are small and neither is worth a package. What they have in common is
/// that a browser has neither: there is no environment to read and no file to
/// open, and `dart:io` cannot even be imported there — so the import lives
/// here, behind the conditional in `host.dart`.
library;

import 'dart:async';
import 'dart:convert';
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

/// Choose a picture and send it to freeq, answering with the URL it is served
/// back at — or an empty string when the reader chose nothing.
///
/// Two platform jobs the core cannot do: a file dialog, and a multipart POST.
///
/// The dialog is a shell-out, like `openUrl` above, and for the same reason —
/// the alternative is a plugin and the dozen packages behind it, for one
/// button. The desktops this runs on have one of these; a machine with none
/// gets a message saying so rather than a button that does nothing.
Future<String> pickAndUpload(
    {required String host,
    required String did,
    required String channel}) async {
  final path = await _chooseFile();
  if (path.isEmpty) return '';

  final file = File(path);
  final bytes = await file.readAsBytes();
  // The endpoint's own cap, refused here rather than after several megabytes
  // have crossed the wire to be turned down.
  if (bytes.length > 10 * 1024 * 1024) {
    throw Exception('That picture is over the 10MB the server takes.');
  }

  // Multipart by hand: it is a boundary, three headers and the bytes, against
  // a package and its dependencies for one request.
  final boundary = '----frq${bytes.length}x${DateTime.now().microsecondsSinceEpoch}';
  final name = path.split(Platform.pathSeparator).last;
  final head = StringBuffer()
    ..write('--$boundary\r\n')
    ..write('Content-Disposition: form-data; name="did"\r\n\r\n$did\r\n');
  if (channel.isNotEmpty) {
    head
      ..write('--$boundary\r\n')
      ..write('Content-Disposition: form-data; name="channel"\r\n\r\n')
      ..write('$channel\r\n');
  }
  head
    ..write('--$boundary\r\n')
    ..write('Content-Disposition: form-data; name="file"; filename="$name"\r\n')
    ..write('Content-Type: image/png\r\n\r\n');

  final body = <int>[
    ...utf8.encode(head.toString()),
    ...bytes,
    ...utf8.encode('\r\n--$boundary--\r\n'),
  ];

  final client = HttpClient();
  try {
    final req = await client.postUrl(Uri.https(host, '/api/v1/upload'));
    req.headers.set('content-type', 'multipart/form-data; boundary=$boundary');
    req.add(body);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw Exception('Upload failed (${res.statusCode})');
    }
    final url = (jsonDecode(text) as Map)['url'] as String? ?? '';
    if (url.isEmpty) {
      throw Exception('The server took the picture but named no URL for it.');
    }
    return url;
  } finally {
    client.close();
  }
}

/// The first file dialog this desktop has, and the path it answered with.
Future<String> _chooseFile() async {
  const dialogs = <String, List<String>>{
    'zenity': ['--file-selection', '--file-filter=Pictures | *.png *.jpg *.jpeg *.gif *.webp'],
    'kdialog': ['--getopenfilename', '.', 'Pictures (*.png *.jpg *.jpeg *.gif *.webp)'],
    'qarma': ['--file-selection'],
    'yad': ['--file-selection'],
  };
  for (final entry in dialogs.entries) {
    try {
      final r = await Process.run(entry.key, entry.value);
      if (r.exitCode == 0) return (r.stdout as String).trim();
      // A non-zero exit is the reader cancelling, which is not an error and
      // must not fall through to the next dialog.
      return '';
    } on ProcessException {
      continue; // not installed; try the next
    }
  }
  throw Exception('No file chooser found — install zenity or kdialog.');
}
