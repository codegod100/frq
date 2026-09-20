/// Which half of the seam this build got.
///
/// The condition is `dart.library.js_interop`, which is true exactly where
/// `dart:ffi` is false. Everything above this file imports these names and
/// never learns which implementation answered — the same arrangement the Nim
/// side has, where `nim/web/frq` shadows `nim/src/frq` by search path.
library;

export 'host_ffi.dart' if (dart.library.js_interop) 'host_js.dart';
