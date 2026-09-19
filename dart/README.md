# The Dart side

Packages that are Dart rather than ClojureDart, and are not Flutter.

## Why this is a separate tree

`frq_core` is the binding to the Nim core in `nim/`. It is `dart:ffi` and
`dart:convert` and nothing else, and keeping it out of `flutter/` buys two
things:

* **It tests on the plain Dart VM.** `flutter/pubspec.yaml` depends on the
  Flutter SDK, so `dart pub get` cannot resolve it at all — anything living
  there needs a Flutter toolchain to run one assertion about a string. This
  package resolves and tests in a second. `just dart-test`.
* **It says which way the dependency goes.** The Flutter app depends on this
  by path. Nothing here may depend on Flutter, and if that ever becomes
  tempting the thing being written belongs on the other side of the line.

## Why Dart and not ClojureDart

The Nim core exists to have less Clojure in the tree. Writing its binding in
ClojureDart would have added some — and would have meant fighting generic
interop for a file that is pure marshalling, since `lookupFunction` takes two
type arguments. In Dart it is a typedef.

So the shape the migration moves toward: Nim owns the rules, Dart owns the
platform, and ClojureDart shrinks from both ends.
