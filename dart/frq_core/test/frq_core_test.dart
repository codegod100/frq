/// The Dart side of the Nim boundary, exercised against the real library.
///
/// Runs on the plain Dart VM — no Flutter, no emulator, no ClojureDart. That
/// is the point: the binding is the risky half of the FFI seam, and it can be
/// proven in a second rather than behind a toolchain that takes minutes.
///
///   just dart-test
///
/// The cases mirror `nim/tests/tircparse.nim` deliberately. Passing there and
/// failing here is a marshalling bug, which is exactly the class of fault
/// this file exists to catch.
import 'dart:io';
import 'package:test/test.dart';
import 'package:frq_core/frq_core.dart' as core;

void main() {
  setUpAll(() {
    if (!File('../../build/nim/libfrqcore.so').existsSync()) {
      throw StateError('build the core first: just nim-lib');
    }
  });

  test('the library loads and reports its version', () {
    expect(core.version, '0.1.0');
  });

  group('parseLine', () {
    test('a bare line', () {
      final p = core.parseLine('PING :12345');
      expect(p['command'], 'PING');
      expect(p['params'], ['12345']);
      expect(p['prefix'], isNull);
      expect(p['tags'], isNull);
    });

    test('a prefix is split off and the command upcased', () {
      final p = core.parseLine(':nick!user@host privmsg #chan :hello there');
      expect(p['prefix'], 'nick!user@host');
      expect(p['command'], 'PRIVMSG');
      expect(p['params'], ['#chan', 'hello there']);
    });

    test('the trailing parameter keeps its spaces and colons', () {
      final p = core.parseLine(':a!b@c PRIVMSG #chan :look: a b  c');
      expect(p['params'], ['#chan', 'look: a b  c']);
    });

    test('an empty trailing parameter is still a parameter', () {
      expect(core.parseLine(':a!b@c TOPIC #chan :')['params'], ['#chan', '']);
    });

    test('tags and the account tag', () {
      final p = core.parseLine('@time=x;account=alice :a!b@c PRIVMSG #c :hi');
      expect(p['tags'], 'time=x;account=alice');
      expect(p['account'], 'alice');
      expect(p['params'], ['#c', 'hi']);
    });

    test('no account tag reads as null, not empty', () {
      expect(core.parseLine('@time=x :a!b@c PRIVMSG #c :hi')['account'], isNull);
    });

    test('raw is what arrived', () {
      expect(core.parseLine('@a=1 :n!u@h PRIVMSG #c :x  ')['raw'],
          '@a=1 :n!u@h PRIVMSG #c :x');
    });

    test('a line that is only tags does not throw', () {
      final p = core.parseLine('@only=tags');
      expect(p['tags'], 'only=tags');
      expect(p['command'], '');
    });

    test('an empty line', () {
      final p = core.parseLine('');
      expect(p['command'], '');
      expect(p['params'], isEmpty);
    });

    test('non-ASCII survives the UTF-8 round trip', () {
      // The whole reason the marshalling is worth testing separately: a
      // handle with an emoji in it is more bytes than characters, and a
      // length taken in the wrong unit truncates mid-codepoint.
      final p = core.parseLine(':né!u@h PRIVMSG #c :héllo 😀 wörld');
      expect(p['prefix'], 'né!u@h');
      expect(p['params'], ['#c', 'héllo 😀 wörld']);
    });
  });

  group('tagValue', () {
    test('a present value', () => expect(core.tagValue('a=1;b=2', 'b'), '2'));
    test('an absent tag', () => expect(core.tagValue('a=1', 'b'), isNull));

    test('an empty value and a bare key are both null', () {
      // IRCv3 says `key` and `key=` mean the same thing. `+reply=` on a line
      // answering nothing used to put a reply chip above it.
      expect(core.tagValue('a=;b=2', 'a'), isNull);
      expect(core.tagValue('a;b=2', 'a'), isNull);
    });

    test('the value is unescaped', () => expect(core.tagValue('t=a\\sb', 't'), 'a b'));

    test('a key that is a prefix of another does not match it', () {
      expect(core.tagValue('account-x=1;account=2', 'account'), '2');
    });
  });

  group('escapes', () {
    test('round-trip', () {
      for (final s in ['plain', 'a;b', 'a b', 'a\\b', 'a\r\nb', '', '😀']) {
        expect(core.unescapeTag(core.escapeTagValue(s)), s, reason: s);
      }
    });
  });

  group('nickOf', () {
    test('a full prefix', () => expect(core.nickOf('nick!user@host'), 'nick'));
    test('a server prefix', () => expect(core.nickOf('irc.freeq.at'), 'irc.freeq.at'));
  });

  uiTests();

  test('ten thousand calls do not leak or crash the allocator', () {
    // The contract this is really testing is ownership: what the core returns
    // is freed with frq_free, what we pass in is freed with libc free, and
    // getting either backwards corrupts a heap rather than failing a check.
    for (var i = 0; i < 10000; i++) {
      core.parseLine('@a=1 :n!u@h PRIVMSG #c :x');
      core.tagValue('a=1;b=2', 'b');
    }
  });
}

/// The UI half of the boundary: a tree out, an event id back.
///
/// These mirror `nim/tests/tui.nim`. Passing there and failing here is a
/// marshalling bug — which, for a structure this nested, is the whole reason
/// to test it twice.
void uiTests() {
  group('the UI tree', () {
    setUp(core.resetUi);

    List<core.UiNode> find(core.UiNode n, String tag) => [
          if (n.tag == tag) n,
          for (final c in n.children) ...find(c, tag),
        ];

    test('renders a page with a title', () {
      final t = core.render();
      expect(t.tag, 'page');
      expect(find(t, 'title').single.prop('label', ''), 'frq');
    });

    test('render is pure across the boundary', () {
      expect(core.render().toString(), core.render().toString());
      expect(find(core.render(), 'entry').length,
          find(core.render(), 'entry').length);
    });

    test('typing into the host field comes back in the tree', () {
      final t = core.dispatch('host.change', 'localhost');
      final host =
          find(t, 'entry').firstWhere((e) => e.prop('key', '') == 'host');
      expect(host.prop('text', ''), 'localhost');
    });

    test('the TLS tick carries the port with it', () {
      var t = core.dispatch('tls.toggle');
      var port =
          find(t, 'entry').firstWhere((e) => e.prop('key', '') == 'port');
      expect(port.prop('text', ''), '6667');
      t = core.dispatch('tls.toggle');
      port = find(t, 'entry').firstWhere((e) => e.prop('key', '') == 'port');
      expect(port.prop('text', ''), '6697');
    });

    test('switching mode changes the fields', () {
      final keys = find(core.dispatch('mode.bluesky'), 'entry')
          .map((e) => e.prop('key', ''))
          .toList();
      expect(keys, contains('handle'));
      expect(keys, isNot(contains('nick')));
    });

    test('connecting swaps the button for a spinner', () {
      expect(find(core.render(), 'spinner'), isEmpty);
      expect(find(core.dispatch('connect'), 'spinner').length, 1);
    });

    test('an empty host is refused and the error is dismissable', () {
      core.dispatch('host.change', '  ');
      var t = core.dispatch('connect');
      expect(find(t, 'card').any((c) => find(c, 'label')
          .any((l) => l.prop('label', '').contains('required'))), isTrue);
      t = core.dispatch('error.dismiss');
      expect(
          find(t, 'button').map((b) => b.prop('label', '')), isNot(contains('Dismiss')));
    });

    test('an unknown event is ignored rather than fatal', () {
      final before = core.render().toString();
      expect(core.dispatch('no.such.event').toString(), before);
    });

    test('non-ASCII survives the tree round trip', () {
      // Bluesky mode first: guest renders no handle field, so the text would
      // have nowhere to appear and the assertion would fail for the wrong
      // reason. It did, on the way in.
      core.dispatch('mode.bluesky');
      final t = core.dispatch('handle.change', 'ünïcøde😀.bsky.social');
      expect(
          find(t, 'entry').any((e) => e.prop('text', '') == 'ünïcøde😀.bsky.social'),
          isTrue);
    });
  });
}
