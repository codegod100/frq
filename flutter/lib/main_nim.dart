/// frq, with Nim owning the state and the screens.
///
/// No ClojureDart on this path at all — not `frq.main`, not `common/`, not a
/// `.cljd` file. Flutter starts, asks Nim for a widget tree and paints it;
/// every tap and keystroke goes back as an event id.
///
///   just nim-ui run
///
/// The screens are ports of `common/frq/screens/`, not sketches of them: same
/// copy, same fields, same stable wrappers. What is not yet here is the emoji
/// picker, the overview strip, the lightbox and the profile card — see
/// `nim/README.md` for what is done and what is not.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:frq_core/frq_core.dart' as core;

import 'nim_renderer.dart';

void main() {
  // FRQ_AUTOCONNECT presses Connect at startup, and FRQ_NICK overrides the
  // nickname — a Wayland window cannot be clicked from a script, so without
  // this the only way to check that the app gets past the connect screen is
  // to sit in front of it.
  //
  // Read here rather than in Nim, and dispatched through the same door the
  // button uses. It lived in `currentTree()` before, which meant the function
  // whose job is "serialise the current screen" opened a socket on its first
  // call depending on the process environment.
  final env = Platform.environment;
  final want = env['FRQ_AUTOCONNECT'] ?? '';
  if (want.isNotEmpty && want != '0') {
    final nick = env['FRQ_NICK'] ?? '';
    if (nick.isNotEmpty) core.dispatch('nick.change', nick);
    core.dispatch('connect');
  }

  runApp(const NimApp());
}
