/// The spike's end to end: connect to a real freeq, join #test, say a line.
///
/// Not in the test suite on purpose. It needs a network, a DNS server and a
/// running freeq, and it sends a message to a public channel — none of which
/// belongs in something CI runs on every push. `just nim-live` runs it when
/// somebody means to.
///
/// Everything below goes through the FFI, so what it proves is the whole
/// stack: Nim's socket, Nim's TLS, Nim's IRC registration, Nim's state, and
/// the Dart boundary over all of it.
import 'dart:io';
import 'package:frq_core/frq_core.dart' as core;

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : 'irc.freeq.at';
  final nick = args.length > 1
      ? args[1]
      : 'frq-spike-${DateTime.now().millisecondsSinceEpoch % 10000}';
  final text = args.length > 2
      ? args[2]
      : 'frq nim spike: hello from Nim over dart:ffi';

  core.resetUi();
  print('→ $host as $nick');

  core.dispatch('nick.change', nick);
  core.dispatch('host.change', host);
  core.dispatch('connect');

  // Poll exactly as the renderer does — same call, same cadence — so this
  // exercises the path the app uses rather than a special one for testing.
  var tree = core.poll();
  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    tree = core.poll();
    if (_find(tree, 'title').any((t) => t.prop('label', '') == '#test')) break;
    final err = _find(tree, 'label')
        .map((l) => l.prop('label', ''))
        .where((l) => l.startsWith('⚠'));
    if (err.isNotEmpty) {
      print('✗ ${err.first}');
      exit(1);
    }
  }

  if (!_find(tree, 'title').any((t) => t.prop('label', '') == '#test')) {
    print('✗ never registered — still on ${_find(tree, "title").map((t) => t.prop("label", ""))}');
    print('  run with FRQ_TRACE=1 to see the wire');
    exit(1);
  }
  print('✓ registered and joined #test');

  core.dispatch('draft.change', text);
  tree = core.dispatch('send');

  final said = _find(tree, 'label').map((l) => l.prop('label', ''));
  if (said.contains(text)) {
    print('✓ sent: $text');
  } else {
    print('✗ the line did not reach the backlog');
    exit(1);
  }

  // Give the server a moment to echo anything back, then leave cleanly so the
  // reader thread is joined rather than killed with the process.
  await Future<void>.delayed(const Duration(seconds: 3));
  for (final m in _find(core.poll(), 'label')) {
    print('   | ${m.prop("label", "")}');
  }
  core.dispatch('disconnect');
  print('✓ disconnected');
}

List<core.UiNode> _find(core.UiNode n, String tag) =>
    [if (n.tag == tag) n, for (final c in n.children) ..._find(c, tag)];
