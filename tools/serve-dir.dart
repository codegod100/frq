// A static file server in one file, for `tools/build-web.sh serve`.
//
// `dart:io` and no packages, so there is nothing to `pub get` and nothing to
// pin: the toolchain already has a Dart, because Flutter ships one, and that
// is the whole reason this is Dart rather than the `python3 -m http.server`
// it replaces. Serving a directory should not add a language to the list of
// things a machine must have.
//
// It is the development server and says so: no caching headers, no
// compression, no range requests. `.modal/flutter-web/serve.py` is the one
// that faces a browser over the internet, and it has all three.
//
//   dart tools/serve-dir.dart <directory> [port]
import 'dart:io';

// Enough of them for a Flutter web bundle, which is HTML, JavaScript, JSON, a
// wasm blob, fonts and images. Anything else goes out as bytes.
const _types = <String, String>{
  '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8',
  '.mjs': 'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff': 'font/woff',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
};

String _typeOf(String path) {
  final dot = path.lastIndexOf('.');
  if (dot < 0) return 'application/octet-stream';
  return _types[path.substring(dot).toLowerCase()] ?? 'application/octet-stream';
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('usage: dart serve-dir.dart <directory> [port]');
    exit(2);
  }
  final root = Directory(args[0]).absolute;
  final port = args.length > 1 ? int.parse(args[1]) : 8080;

  // 0.0.0.0 and not loopback: in the container this is behind a Modal tunnel,
  // and a server bound to 127.0.0.1 is one the tunnel cannot reach.
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('serving ${root.path} on :$port');

  await for (final request in server) {
    var path = Uri.decodeComponent(request.uri.path);
    if (path.endsWith('/')) path = '${path}index.html';
    while (path.startsWith('/')) path = path.substring(1);
    // The one rule that is not "read the file": a path that escapes the root
    // is refused rather than resolved. This binds to 0.0.0.0, which in a
    // container means the internet is one tunnel away.
    final file = File('${root.path}/$path').absolute;
    final resolved = file.path;
    if (!resolved.startsWith(root.path)) {
      request.response.statusCode = HttpStatus.forbidden;
      await request.response.close();
      continue;
    }
    if (!await file.exists()) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('not found: $path');
      await request.response.close();
      continue;
    }
    request.response.headers.contentType = ContentType.parse(_typeOf(resolved));
    // A single-page app served from a build directory: nothing here is
    // versioned by name, so every response is one the browser must re-ask for.
    request.response.headers.set('cache-control', 'no-store');
    await request.response.addStream(file.openRead());
    await request.response.close();
  }
}
