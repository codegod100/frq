/// The native half of the seam: `libfrqcore.so`, through `dart:ffi`.
///
/// Split out of `frq_core.dart` so that file can be imported where there is
/// no `dart:ffi` to import — a browser. `host.dart` picks this or `host_js`
/// and nothing above it knows which.
///
/// The two rules of the ABI live here, wrapped so no call site repeats them:
/// `frq_init` runs once before anything else, and every string the core
/// returns is ours to free with `frq_free`.
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

// Every entry point resolved once, here, rather than on each call.
//
// `lookupFunction` is a dlsym plus a freshly built trampoline closure every
// time it runs. At 10Hz for `poll` and once per keystroke for `dispatch` that
// is measurable and, more to the point, free to avoid — these are `final`, so
// they cost one lookup for the life of the process.
final _free = _lib.lookupFunction<_FreeNative, _FreeDart>('frq_free');
final _version = _lib.lookupFunction<_VersionNative, _VersionDart>('frq_version');
final _tagValue = _lib.lookupFunction<_Str2Native, _Str2Dart>('frq_irc_tag_value');
final _traceFn = _lib.lookupFunction<_Str2Native, _Str2Dart>('frq_trace');
final _connOpen = _lib.lookupFunction<_ConnOpenNative, _ConnOpenDart>('frq_conn_open');
final _connSend = _lib.lookupFunction<_Str1Native, _Str1Dart>('frq_conn_send');
final _connCloseFn = _lib.lookupFunction<_VoidNative, _VoidDart>('frq_conn_close');
final _connRecvFn = _lib.lookupFunction<_Str0Native, _Str0Dart>('frq_conn_recv');
final _connEventFn = _lib.lookupFunction<_Str0Native, _Str0Dart>('frq_conn_event');
final _uiRender = _lib.lookupFunction<_Str0Native, _Str0Dart>('frq_ui_render');
final _uiPoll = _lib.lookupFunction<_Str0Native, _Str0Dart>('frq_ui_poll');
final _uiDispatch = _lib.lookupFunction<_Str1Native, _Str1Dart>('frq_ui_dispatch');
final _uiDemo = _lib.lookupFunction<_VoidNative, _VoidDart>('frq_ui_demo');
final _uiWantedPicture =
    _lib.lookupFunction<_Str0Native, _Str0Dart>('frq_ui_wanted_picture');
final _uiReset = _lib.lookupFunction<_VoidNative, _VoidDart>('frq_ui_reset');
final _str1 = <String, _Str1Dart>{};

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

/// Call a two-strings-in, one-string-out entry point.
///
/// The mirror of [_call1], and it exists for the same reason: the
/// `_toC`/`try`/`finally`/`_freeArg` dance is four lines of ownership
/// bookkeeping that no call site should repeat.
String? _call2(_Str2Dart f, String x, String y) {
  final a = _toC(x);
  final b = _toC(y);
  try {
    return _takeString(f(a, b));
  } finally {
    _freeArg(a);
    _freeArg(b);
  }
}

/// Call a one-string-in, one-string-out entry point.
String? _call1(String symbol, String arg) {
  final f = _str1.putIfAbsent(
      symbol, () => _lib.lookupFunction<_Str1Native, _Str1Dart>(symbol));
  final a = _toC(arg);
  try {
    return _takeString(f(a));
  } finally {
    _freeArg(a);
  }
}


typedef _ConnOpenNative = Void Function(Pointer<Uint8>, Int32, Int32);
typedef _ConnOpenDart = void Function(Pointer<Uint8>, int, int);

// ------------------------------------------------------------------ the host
//
// What `frq_core.dart` calls, and what `host_js.dart` answers with the same
// names. Everything above is how; this is what.

String? uiRender() => _takeString(_uiRender());
String? uiPoll() => _takeString(_uiPoll());

String? uiDispatch(String event) {
  final a = _toC(event);
  try {
    return _takeString(_uiDispatch(a));
  } finally {
    _freeArg(a);
  }
}

void uiDemo() => _uiDemo();

String? wantedPicture() => _takeString(_uiWantedPicture());
void uiReset() => _uiReset();

/// Static storage on the Nim side: the one return value that is NOT freed.
String hostVersion() {
  final p = _version();
  var len = 0;
  while (p[len] != 0) {
    len++;
  }
  return utf8.decode(p.asTypedList(len));
}

String? str1(String symbol, String arg) => _call1(symbol, arg);
String? tagValueOf(String tags, String key) => _call2(_tagValue, tags, key);
void traceTo(String topic, String msg) {
  _call2(_traceFn, topic, msg);
}

void connOpenAt(String host, int port, bool tls) {
  final h = _toC(host);
  try {
    _connOpen(h, port, tls ? 1 : 0);
  } finally {
    _freeArg(h);
  }
}

void connSendLine(String line) {
  final a = _toC(line);
  try {
    _connSend(a);
  } finally {
    _freeArg(a);
  }
}

void connCloseNow() => _connCloseFn();
String? connRecvLine() => _takeString(_connRecvFn());
String? connEventNext() => _takeString(_connEventFn());
