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
/// Two platform jobs the core cannot do: finding the picture, and a multipart
/// POST. `source` is where to find it: `file` opens a dialog, `clipboard`
/// takes the picture the reader just pasted.
///
/// The dialog is a shell-out, like `openUrl` above, and for the same reason —
/// the alternative is a plugin and the dozen packages behind it, for one
/// button. The desktops this runs on have one of these; a machine with none
/// gets a message saying so rather than a button that does nothing.
Future<String> pickAndUpload(
    {required String host,
    required String did,
    required String channel,
    String source = 'file'}) async {
  final List<int> bytes;
  final String name;
  final String mime;
  if (source == 'clipboard') {
    final pasted = await _clipboardPicture();
    // Gone between the keypress and now: somebody copied something else.
    if (pasted == null) return '';
    bytes = pasted.bytes;
    mime = pasted.mime;
    name = 'pasted.${_extensionFor(mime)}';
  } else {
    final path = await _chooseFile();
    if (path.isEmpty) return '';
    bytes = await File(path).readAsBytes();
    name = path.split(Platform.pathSeparator).last;
    mime = _mimeFor(name);
  }
  return _upload(host: host, did: did, channel: channel,
      bytes: bytes, name: name, mime: mime);
}

/// Whether the clipboard is holding a picture, rather than text.
///
/// Asked when the reader presses paste in the message box. Flutter's own
/// clipboard is text and nothing else, so this is a shell-out too: `wl-paste`
/// on Wayland and `xclip` on X, whichever answers. A desktop with neither has
/// no picture to find, and the paste goes on being the text paste it was —
/// no error, since most pastes are text and none of them should warn.
Future<bool> clipboardHasPicture() async =>
    (await _findClipboardPicture()).$1.isNotEmpty;

/// The clipboard tools, as (list the types, read one type) — in the order
/// they are tried.
final _clipboards = <(List<String>, List<String> Function(String))>[
  (['wl-paste', '--list-types'], (t) => ['wl-paste', '--no-newline', '--type', t]),
  (['xclip', '-selection', 'clipboard', '-t', 'TARGETS', '-o'],
      (t) => ['xclip', '-selection', 'clipboard', '-t', t, '-o']),
];

/// The picture types freeq takes, most wanted first.
const _pictureTypes = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];

/// The picture type on the clipboard and the command that reads it, or an
/// empty type where there is none.
Future<(String, List<String>)> _findClipboardPicture() async {
  for (final (list, read) in _clipboards) {
    try {
      final r = await Process.run(list.first, list.sublist(1));
      // No display for this tool — Wayland's on X, or the other way round.
      if (r.exitCode != 0) continue;
      final offered = (r.stdout as String)
          .split('\n')
          .map((l) => l.trim())
          .toSet();
      for (final t in _pictureTypes) {
        if (offered.contains(t)) return (t, read(t));
      }
      // This tool answered, and what it holds is not a picture.
      return ('', const <String>[]);
    } on ProcessException {
      continue; // not installed; try the next
    }
  }
  return ('', const <String>[]);
}

/// The picture on the clipboard, as bytes and a type, or null for none.
Future<({List<int> bytes, String mime})?> _clipboardPicture() async {
  final (mime, read) = await _findClipboardPicture();
  if (mime.isEmpty) return null;
  final r = await Process.run(read.first, read.sublist(1), stdoutEncoding: null);
  final bytes = r.stdout as List<int>;
  if (r.exitCode != 0 || bytes.isEmpty) return null;
  return (bytes: bytes, mime: mime);
}

String _extensionFor(String mime) => switch (mime) {
      'image/jpeg' => 'jpg',
      'image/gif' => 'gif',
      'image/webp' => 'webp',
      _ => 'png',
    };

String _mimeFor(String name) {
  final lower = name.toLowerCase();
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.webp')) return 'image/webp';
  return 'image/png';
}

/// Send a picture to freeq's media endpoint, and answer with its URL.
Future<String> _upload(
    {required String host,
    required String did,
    required String channel,
    required List<int> bytes,
    required String name,
    required String mime}) async {
  // The endpoint's own cap, refused here rather than after several megabytes
  // have crossed the wire to be turned down.
  if (bytes.length > 10 * 1024 * 1024) {
    throw Exception('That picture is over the 10MB the server takes.');
  }

  // Multipart by hand: it is a boundary, three headers and the bytes, against
  // a package and its dependencies for one request.
  final boundary = '----frq${bytes.length}x${DateTime.now().microsecondsSinceEpoch}';
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
    ..write('Content-Type: $mime\r\n\r\n');

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
