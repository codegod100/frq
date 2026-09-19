/// The spike's entry point: a Flutter app whose screens come from Nim.
///
/// No ClojureDart anywhere on this path — not `frq.main`, not `common/`, not
/// a `.cljd` file. Flutter starts, asks Nim for a tree, and paints it; every
/// tap and keystroke goes back as an event id. That is the whole program.
///
///   just nim-spike
///
/// It renders the connect screen, which is the one with enough in it to be a
/// real test: text fields that must keep a controller, a checkbox whose tick
/// changes another field, mode buttons that swap which fields exist, and an
/// error that appears and dismisses.
import 'package:flutter/material.dart';
import 'nim_renderer.dart';

void main() => runApp(const NimApp());
