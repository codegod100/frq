# The Dart side

Packages that are Dart rather than ClojureDart, and are not Flutter.

## Why this is a separate tree

`frq_core` is the binding to the Nim core in `nim/`. It is `dart:ffi` and
`dart:convert` and nothing else, and keeping it out of `flutter/` buys two
things:

* **It tests on the plain Dart VM.** `flutter/pubspec.yaml` depends on the
  Flutter SDK, so `dart pub get` cannot resolve it at all — anything living
  there needs a Flutter toolchain to run one assertion about a string. This
  package resolves and tests in a second. `just test dart`.
* **It says which way the dependency goes.** The Flutter app depends on this
  by path. Nothing here may depend on Flutter, and if that ever becomes
  tempting the thing being written belongs on the other side of the line.

## Why Dart

The binding was ClojureDart for exactly one commit, which is how it got its
own README section. Writing it in the language being removed meant fighting
generic interop — `lookupFunction` takes two type arguments — for a file that
is pure marshalling. In Dart it is a typedef.

The ClojureDart is all gone now, and the shape it left is the one to keep:
Nim owns the rules, Dart owns the platform.
