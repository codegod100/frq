/// The whole stack, end to end: Nim's socket, Nim's state, Nim's screens.
///
/// Connects to a real freeq, waits for the room list to fill, opens a room and
/// prints what the tree actually contains. Everything goes through the FFI, so
/// what it proves is the same path the window uses.
///
/// Not in any test suite: it needs a network and a running freeq.
///
/// With FRQ_TEST_HANDLE and FRQ_TEST_APP_PASSWORD set it signs in with that
/// account's app password rather than connecting as a guest, and checks that
/// freeq took the sign-in — a refused SASL carries on as a guest, which looks
/// like a success from the chats screen. `tools/set-test-account-github-secrets`
/// puts the pair where `.github/workflows/live.yml` reads it.
///
/// With FRQ_TEST_ROOM set it joins that room rather than opening whichever
/// comes first, and fails unless the room shows messages — the backlog a
/// signed-in reader is meant to see on arrival.
///
/// The one line it sends always goes to #test, whichever room it read: the
/// others are real conversations, and a line from CI does not belong in them.
///
///   just test live
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

  final handle = Platform.environment['FRQ_TEST_HANDLE'] ?? '';
  final password = Platform.environment['FRQ_TEST_APP_PASSWORD'] ?? '';
  final signedIn = handle.isNotEmpty && password.isNotEmpty;
  final room = Platform.environment['FRQ_TEST_ROOM'] ?? '';
  const sendRoom = '#test';

  core.resetUi();
  print(signedIn ? '→ $host as $handle, by app password' : '→ $host as $nick');

  core.dispatch('nick.change', nick);
  core.dispatch('host.change', host);
  if (signedIn) {
    core.dispatch('mode.app-password');
    core.dispatch('handle.change', handle);
    core.dispatch('app-password.change', password);
  }
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
  // Signed in, the nick is whatever handle the PDS answered with — the same
  // name, maybe cased differently from what was typed.
  final me = labels(tree, 'title')
      .firstWhere((l) => l.startsWith('Logged in as'))
      .substring('Logged in as '.length);
  if (signedIn && me.toLowerCase() != handle.toLowerCase()) {
    print('✗ logged in as $me, not $handle');
    exit(1);
  }

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

  // Open one and look at the conversation: the room asked for, joined if
  // need be, or else whichever the list has first.
  if (room.isEmpty) {
    tree = core.dispatch('room.open:${rooms.first}');
    await Future<void>.delayed(const Duration(seconds: 2));
    tree = core.poll();
  } else {
    tree = core
        .dispatch(rooms.contains(room) ? 'room.open:$room' : 'room.join:$room');
    // The backlog comes after the JOIN, by CHATHISTORY; wait for it.
    final backlogBy = DateTime.now().add(const Duration(seconds: 15));
    while (DateTime.now().isBefore(backlogBy)) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      tree = core.poll();
      if (find(tree, 'text').isNotEmpty) break;
    }
    // A moment more, so a backlog arriving in batches is read whole.
    await Future<void>.delayed(const Duration(seconds: 2));
    tree = core.poll();
  }

  print('✓ chat screen: ${labels(tree, "title").first}');
  final said = find(tree, 'text').map((e) => e.prop('text', '')).toList();
  print('✓ ${said.length} text runs, ${find(tree, "link").length} links, '
      '${find(tree, "avatar").length} avatars, '
      '${find(tree, "reaction").length} reaction chips, '
      '${find(tree, "separator").length} separators');
  final shown =
      room.isEmpty ? said.take(6) : said.reversed.take(12).toList().reversed;
  for (final line in shown) {
    print('   | $line');
  }
  if (room.isNotEmpty) {
    final title = labels(tree, 'title').first;
    if (!title.contains(room)) {
      print('✗ asked for $room, landed on $title');
      exit(1);
    }
    if (said.isEmpty) {
      print('✗ no messages visible in $room');
      exit(1);
    }
    print('✓ ${said.length} text runs visible in $room');
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

  // Send a line, and count how many times it comes back on screen.
  //
  // echo-message is negotiated, so the server returns every line this client
  // sends — and showing both that and the local copy is what put every sent
  // message on screen twice.
  //
  // Sent in the test room and nowhere else, joined if need be.
  tree = core.dispatch(rooms.contains(sendRoom)
      ? 'room.open:$sendRoom'
      : 'room.join:$sendRoom');
  await Future<void>.delayed(const Duration(seconds: 2));
  tree = core.poll();
  final sendTitle = labels(tree, 'title').first;
  if (!sendTitle.contains(sendRoom)) {
    print('✗ meant to send in $sendRoom, but on $sendTitle — not sending');
    exit(1);
  }
  final marker = 'frq echo check ${DateTime.now().millisecondsSinceEpoch}';
  core.dispatch('draft.change', marker);
  core.dispatch('send');
  await Future<void>.delayed(const Duration(seconds: 3));
  tree = core.poll();
  final copies = find(tree, 'text')
      .where((e) => e.prop('text', '') == marker)
      .length;
  if (copies == 1) {
    print('✓ sent line appears once');
  } else {
    print('✗ sent line appears $copies times');
    exit(1);
  }

  // Whether freeq took the sign-in. The echo of our own line is the proof: a
  // signed-in sender's line carries an `account` tag, and the name on it then
  // opens the profile by DID rather than by nick.
  if (signedIn) {
    final opens = find(tree, 'button')
        .where((b) => b.prop('label', '') == me)
        .map((b) => b.prop('onClick', ''))
        .toList();
    final did = opens.firstWhere((o) => o.contains(':did:'), orElse: () => '');
    if (did.isEmpty) {
      print('✗ freeq did not see $me as signed in (echo opens $opens)');
      exit(1);
    }
    print('✓ freeq knows $me as ${did.substring(did.indexOf(':did:') + 1)}');
  }

  core.dispatch('disconnect');
  print('✓ disconnected');
}
