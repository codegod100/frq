/// The whole stack, end to end: Nim's socket, Nim's state, Nim's screens.
///
/// Connects to a real freeq, waits for the room list to fill, opens a room and
/// prints what the tree actually contains. Everything goes through the FFI, so
/// what it proves is the same path the window uses.
///
/// Not in any test suite: it needs a network and a running freeq.
///
///   just nim-live
import 'dart:io';
import 'package:frq_core/frq_core.dart' as core;

List<core.UiNode> find(core.UiNode n, String tag) =>
    [if (n.tag == tag) n, for (final c in n.children) ...find(c, tag)];

List<String> labels(core.UiNode n, String tag) =>
    find(n, tag).map((e) => e.prop('label', '')).toList();

Future<void> main(List<String> args) async {
  final host = args.isNotEmpty ? args[0] : 'irc.freeq.at';
  final nick = args.length > 1
      ? args[1]
      : 'frq-ui-${DateTime.now().millisecondsSinceEpoch % 10000}';

  core.resetUi();
  print('→ $host as $nick');

  core.dispatch('nick.change', nick);
  core.dispatch('host.change', host);
  var tree = core.dispatch('connect');

  final deadline = DateTime.now().add(const Duration(seconds: 25));
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    tree = core.poll();
    if (labels(tree, 'title').any((l) => l.startsWith('Logged in as'))) break;
    final err = labels(tree, 'label').where((l) => l.startsWith('⚠'));
    if (err.isNotEmpty) {
      print('✗ ${err.first}');
      exit(1);
    }
  }

  if (!labels(tree, 'title').any((l) => l.startsWith('Logged in as'))) {
    print('✗ never reached the chats screen — still ${labels(tree, "title")}');
    exit(1);
  }
  print('✓ chats screen: ${labels(tree, "title").first}');

  // The room list, from the real server. Waited for rather than read on the
  // instant we land: registration finishes before the JOIN echo that creates
  // the buffer, so reading immediately is reading too early.
  final roomsBy = DateTime.now().add(const Duration(seconds: 10));
  var rooms = <String>[];
  while (DateTime.now().isBefore(roomsBy)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    tree = core.poll();
    rooms = labels(tree, 'title-2');
    if (rooms.isNotEmpty) break;
  }
  print('✓ rooms: $rooms');
  if (rooms.isEmpty) {
    print('✗ no rooms in the list');
    exit(1);
  }

  // Open one and look at the conversation.
  tree = core.dispatch('room.open:${rooms.first}');
  await Future<void>.delayed(const Duration(seconds: 2));
  tree = core.poll();

  print('✓ chat screen: ${labels(tree, "title").first}');
  final said = find(tree, 'text').map((e) => e.prop('text', '')).toList();
  print('✓ ${said.length} text runs, ${find(tree, "link").length} links, '
      '${find(tree, "avatar").length} avatars, '
      '${find(tree, "reaction").length} reaction chips, '
      '${find(tree, "separator").length} separators');
  for (final line in said.take(6)) {
    print('   | $line');
  }

  // Every tag the tree contains, so an unrendered one shows up here rather
  // than as an orange box in the window.
  final tags = <String>{};
  void walk(core.UiNode n) {
    tags.add(n.tag);
    for (final c in n.children) {
      walk(c);
    }
  }

  walk(tree);
  print('✓ tags in use: ${(tags.toList()..sort()).join(", ")}');

  core.dispatch('disconnect');
  print('✓ disconnected');
}
