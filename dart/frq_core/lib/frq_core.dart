/// The Nim core, as Dart functions.
///
/// This is the whole of what knows `libfrqcore.so` is a native library; see
/// `nim/README.md` for why the logic is there rather than under `common/`.
///
/// **Dart and not ClojureDart, on purpose.** The point of the Nim core is to
/// have less Clojure, so new code on this side of the boundary is written in
/// the language the platform speaks. It also sidesteps a real problem:
/// `lookupFunction` takes two type arguments, and generic interop is the part
/// of ClojureDart least worth fighting for a file that is pure marshalling.
///
/// No `package:ffi` either. That package exists mostly for `Utf8`
/// conversions, and doing them here against `dart:convert` costs about ten
/// lines and keeps `pubspec.yaml` unchanged — which matters because every
/// dependency added here has to work on three targets.
///
/// The two rules of the ABI, wrapped so no call site repeats them:
///
///  * `frq_init` runs once before anything else. [_lib] does it on the way
///    out, so holding the handle means it has happened.
///  * Every string the core returns is **ours to free**, with `frq_free`.
///    [_takeString] is that, in a `finally` so a throw between the read and
///    the free does not leak. Nim's allocator is not Dart's, so calling
///    `malloc.free` on one of these pointers is undefined rather than merely
///    untidy.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

// ---------------------------------------------------------------- the ABI

typedef _InitNative = Void Function();
typedef _InitDart = void Function();

typedef _FreeNative = Void Function(Pointer<Uint8>);
typedef _FreeDart = void Function(Pointer<Uint8>);

typedef _VersionNative = Pointer<Uint8> Function();
typedef _VersionDart = Pointer<Uint8> Function();

typedef _Str1Native = Pointer<Uint8> Function(Pointer<Uint8>);
typedef _Str1Dart = Pointer<Uint8> Function(Pointer<Uint8>);

typedef _Str2Native = Pointer<Uint8> Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _Str2Dart = Pointer<Uint8> Function(Pointer<Uint8>, Pointer<Uint8>);

typedef _Str0Native = Pointer<Uint8> Function();
typedef _Str0Dart = Pointer<Uint8> Function();

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();

/// Where to look for the library, in order.
///
/// Android resolves a bare soname out of the APK's `lib/<abi>/`. A desktop
/// build has no such rule, so the bare name is tried first (it works when the
/// object sits beside the executable or on the loader path) and then the
/// development path `just nim-lib` writes to. Named explicitly rather than by
/// exporting `LD_LIBRARY_PATH` from a launcher, because a variable set in a
/// wrapper script is a thing that works until someone starts the binary
/// another way.
DynamicLibrary _open() {
  if (Platform.isAndroid) return DynamicLibrary.open('libfrqcore.so');
  // The development paths are relative to whichever directory the process
  // started in: `dart test` runs from `dart/frq_core`, a built desktop bundle
  // from the repo root. All of them are tried rather than guessing which
  // invocation this is, because the failure mode is a StateError at first use
  // rather than anything a type checker would have caught.
  for (final p in [
    'libfrqcore.so',
    'build/nim/libfrqcore.so',
    '../build/nim/libfrqcore.so',     // `flutter test`, from flutter/
    '../../build/nim/libfrqcore.so',  // `dart test`, from dart/frq_core/
  ]) {
    try {
      return DynamicLibrary.open(p);
    } on ArgumentError {
      continue;
    }
  }
  throw StateError(
      'libfrqcore.so not found — build it with `just nim-lib`, or ship it '
      'beside the executable');
}

final DynamicLibrary _lib = () {
  final lib = _open();
  lib.lookupFunction<_InitNative, _InitDart>('frq_init')();
  return lib;
}();

final _free = _lib.lookupFunction<_FreeNative, _FreeDart>('frq_free');

/// The bytes at [p] as a string, with [p] freed afterwards. Null in, null out.
String? _takeString(Pointer<Uint8> p) {
  if (p == nullptr) return null;
  try {
    // Walk to the NUL rather than asking for a length the ABI does not carry.
    var len = 0;
    while (p[len] != 0) {
      len++;
    }
    return utf8.decode(p.asTypedList(len));
  } finally {
    _free(p);
  }
}

/// [s] as a NUL-terminated C string that the CALLER must free with [_freeArg].
///
/// Allocated with `malloc` from Dart's side, so it is freed from Dart's side —
/// the mirror of the rule for what comes back. The core never takes ownership
/// of an argument.
Pointer<Uint8> _toC(String s) {
  final bytes = utf8.encode(s);
  final p = _malloc(bytes.length + 1).cast<Uint8>();
  for (var i = 0; i < bytes.length; i++) {
    p[i] = bytes[i];
  }
  p[bytes.length] = 0;
  return p;
}

// malloc/free out of libc rather than package:ffi's allocator, for the same
// reason the rest of this file avoids that package: one less dependency to
// carry to three targets, for two symbols that are always there.
final DynamicLibrary _libc =
    Platform.isWindows ? DynamicLibrary.open('msvcrt.dll') : DynamicLibrary.process();
final _malloc = _libc
    .lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>('malloc');
final _freeArg =
    _libc.lookupFunction<Void Function(Pointer<Uint8>), void Function(Pointer<Uint8>)>('free');

/// Call a one-string-in, one-string-out entry point.
String? _call1(String symbol, String arg) {
  final f = _lib.lookupFunction<_Str1Native, _Str1Dart>(symbol);
  final a = _toC(arg);
  try {
    return _takeString(f(a));
  } finally {
    _freeArg(a);
  }
}

// ------------------------------------------------------------------ public

/// The core's version, for a caller that wants to check the library it found
/// is the one it was built against. Static storage on the Nim side: the one
/// return value that is NOT freed.
String get version {
  final p = _lib.lookupFunction<_VersionNative, _VersionDart>('frq_version')();
  var len = 0;
  while (p[len] != 0) {
    len++;
  }
  return utf8.decode(p.asTypedList(len));
}

/// An IRC line, taken apart: `{raw, tags, account, prefix, command, params}`.
///
/// `tags`, `account` and `prefix` are null where the line carried none, which
/// is the distinction `frq.irc.parse` draws with nil and every caller depends
/// on — a PRIVMSG from a server with no prefix is not the same line as one
/// from a nick.
Map<String, dynamic> parseLine(String line) {
  final json = _call1('frq_irc_parse_line', line);
  return jsonDecode(json ?? 'null') as Map<String, dynamic>;
}

/// One IRCv3 tag's value, unescaped — null where the tag is absent OR empty,
/// which IRCv3 says are the same thing.
String? tagValue(String tags, String key) {
  final f = _lib.lookupFunction<_Str2Native, _Str2Dart>('frq_irc_tag_value');
  final a = _toC(tags);
  final b = _toC(key);
  try {
    return _takeString(f(a, b));
  } finally {
    _freeArg(a);
    _freeArg(b);
  }
}

String unescapeTag(String v) => _call1('frq_irc_unescape_tag', v) ?? '';

String escapeTagValue(String v) => _call1('frq_irc_escape_tag_value', v) ?? '';

/// The nick half of a `nick!user@host` prefix.
String nickOf(String prefix) => _call1('frq_irc_nick_of', prefix) ?? '';


/// Log through the Nim core's trace facility, so `FRQ_TRACE=1` gives one
/// interleaved story rather than two half-ones in different places.
void trace(String topic, String msg) {
  final f = _lib.lookupFunction<_Str2Native, _Str2Dart>('frq_trace');
  final a = _toC(topic);
  final b = _toC(msg);
  try {
    f(a, b);
  } finally {
    _freeArg(a);
    _freeArg(b);
  }
}

// --------------------------------------------------------------- transport
//
// `frq.net`'s three operations, with a Nim socket behind them. This is the
// wiring that leaves the existing ClojureDart screens, cells and actions
// alone: only the transport underneath them is Nim.

typedef _ConnOpenNative = Void Function(Pointer<Uint8>, Int32, Int32);
typedef _ConnOpenDart = void Function(Pointer<Uint8>, int, int);

/// Dial. Non-blocking: the socket runs on a Nim thread and progress arrives
/// through [connEvent].
void connOpen(String host, int port, {bool tls = true}) {
  final f = _lib.lookupFunction<_ConnOpenNative, _ConnOpenDart>('frq_conn_open');
  final a = _toC(host);
  try {
    f(a, port, tls ? 1 : 0);
  } finally {
    _freeArg(a);
  }
}

/// Queue a line. The transport adds the CRLF.
void connSend(String line) {
  final f = _lib.lookupFunction<_Str1Native, _Str1Dart>('frq_conn_send');
  final a = _toC(line);
  try {
    f(a);
  } finally {
    _freeArg(a);
  }
}

void connClose() =>
    _lib.lookupFunction<_VoidNative, _VoidDart>('frq_conn_close')();

/// The next line, or null when none is waiting. Never blocks.
String? connRecv() => _takeString(
    _lib.lookupFunction<_Str0Native, _Str0Dart>('frq_conn_recv')());

/// The next transport event — `open`, `close: …`, `error: …` — or null.
String? connEvent() => _takeString(
    _lib.lookupFunction<_Str0Native, _Str0Dart>('frq_conn_event')());


// ---------------------------------------------------------------- the UI
//
// Nim owns the state and the screens; Dart owns the pixels. A tree goes out,
// an event id comes back, and nothing else crosses.
//
// `UiNode` is deliberately a dumb bag — a tag, a props map, children. A class
// per widget would put the tag vocabulary in two places and make every new tag
// a change on both sides; the point is that Nim can grow a screen without this
// file being touched.

/// One node of the widget tree Nim emitted.
class UiNode {
  final String tag;
  final Map<String, dynamic> props;
  final List<UiNode> children;

  const UiNode(this.tag, this.props, this.children);

  factory UiNode.fromJson(Map<String, dynamic> j) => UiNode(
        j['tag'] as String,
        (j['props'] as Map?)?.cast<String, dynamic>() ?? const {},
        ((j['children'] as List?) ?? const [])
            .map((c) => UiNode.fromJson((c as Map).cast<String, dynamic>()))
            .toList(growable: false),
      );

  /// A prop, or [fallback] when it is absent or the wrong shape. Tolerant on
  /// purpose: a renderer should skip a prop it does not understand rather than
  /// fail a whole screen over one.
  T prop<T>(String name, T fallback) {
    final v = props[name];
    return v is T ? v : fallback;
  }

  /// Structural, and that matters: the poll loop compares two trees by this
  /// string to decide whether to rebuild. A summary showing only tags and prop
  /// NAMES would call two screens equal when a message had arrived, and the
  /// room would never appear to fill.
  @override
  String toString() =>
      '<$tag $props ${children.map((c) => c.toString()).join()}>';
}

UiNode _treeFrom(String? json) =>
    UiNode.fromJson(jsonDecode(json ?? '{"tag":"vbox"}') as Map<String, dynamic>);

/// The current screen.
///
/// Not pure: the Nim side drains the socket's queue first, so two calls with
/// no [dispatch] between can differ when a line arrived in the gap. That is how
/// the room fills, and why the renderer polls.
UiNode render() => _treeFrom(
    _takeString(_lib.lookupFunction<_Str0Native, _Str0Dart>('frq_ui_render')()));

/// The tree, asked for because time passed rather than because anything
/// happened. Same work as [render]; named for what the caller means.
UiNode poll() => _treeFrom(
    _takeString(_lib.lookupFunction<_Str0Native, _Str0Dart>('frq_ui_poll')()));

/// Apply an event and get the tree it produced.
///
/// One call rather than dispatch-then-render, and not to save a crossing: it
/// makes the pair atomic, so there is no window in which Dart could render a
/// state nothing asked for.
UiNode dispatch(String id, [String value = '']) {
  final f = _lib.lookupFunction<_Str1Native, _Str1Dart>('frq_ui_dispatch');
  final a = _toC(jsonEncode({'id': id, 'value': value}));
  try {
    return _treeFrom(_takeString(f(a)));
  } finally {
    _freeArg(a);
  }
}

/// Fill a room with a representative conversation, so a test can lay the chat
/// screen out without a server. See the Nim side for why it exists.
void demoUi() =>
    _lib.lookupFunction<_VoidNative, _VoidDart>('frq_ui_demo')();

/// Back to a fresh state, for a caller that wants a known starting point.
void resetUi() =>
    _lib.lookupFunction<_VoidNative, _VoidDart>('frq_ui_reset')();
