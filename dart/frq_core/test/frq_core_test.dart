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
