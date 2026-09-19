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
import 'package:flutter/material.dart';
import 'nim_renderer.dart';

void main() => runApp(const NimApp());
