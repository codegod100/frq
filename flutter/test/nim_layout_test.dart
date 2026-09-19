/// Every screen, laid out for real, at sizes that squeeze.
///
/// This is the test that was missing. `Cannot hit test a render box that has
/// never been laid out` is what a failed layout looks like from the outside,
/// and nothing automated ever laid the chat screen out — a GUI on Wayland
/// cannot be clicked, so every check stopped at the room list while the
/// biggest screen in the app went out unverified.
///
/// `tester.takeException()` is the whole point: a layout error is reported to
/// FlutterError rather than thrown at the caller, so a test that only pumps
/// and asserts on widgets passes while the screen is broken. These fail.
///
///   just test layout
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frq_core/frq_core.dart' as core;
import 'package:frq/nim_renderer.dart';

/// Phone, small desktop, and a deliberately cramped one. The head row of the
/// chat screen asks for more than 360 points has, which is why it wraps.
const sizes = <String, Size>{
  'phone': Size(360, 690),
  'desktop': Size(1280, 800),
  'cramped': Size(300, 500),
};

Future<void> layOut(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(const NimApp());
  await tester.pump();
}

/// Nothing went to FlutterError while that frame was built.
void expectLaidOut(WidgetTester tester, String what) {
  final e = tester.takeException();
  expect(e, isNull, reason: '$what reported: $e');
}

void main() {
  // No offline guard needed: `demoUi` sets the state directly and none of
  // these dispatch `connect`, so nothing here opens a socket.

  group('the connect screen', () {
    for (final entry in sizes.entries) {
      testWidgets('lays out at ${entry.key}', (tester) async {
        core.resetUi();
        await layOut(tester, entry.value);
        expectLaidOut(tester, 'connect at ${entry.key}');
      });
    }

    testWidgets('lays out in every auth mode', (tester) async {
      for (final mode in ['guest', 'bluesky', 'app-password']) {
        core.resetUi();
        core.dispatch('mode.$mode');
        await layOut(tester, sizes['phone']!);
        expectLaidOut(tester, 'connect in $mode');
      }
    });
  });

  group('the chat screen', () {
    // The one that was never laid out by anything automated.
    for (final entry in sizes.entries) {
      testWidgets('lays out at ${entry.key}', (tester) async {
        core.demoUi();
        await layOut(tester, entry.value);
        expectLaidOut(tester, 'chat at ${entry.key}');
      });
    }

    testWidgets('renders the conversation it was given', (tester) async {
      core.demoUi();
      await layOut(tester, sizes['desktop']!);
      expect(find.text('hello there'), findsOneWidget);
      expect(find.text('#test'), findsWidgets);
      expectLaidOut(tester, 'chat content');
    });

    testWidgets('lays out with the people panel up', (tester) async {
      core.demoUi();
      core.dispatch('users.toggle');
      await layOut(tester, sizes['desktop']!);
      expectLaidOut(tester, 'chat with people');
    });

    testWidgets('lays out with every compose banner showing', (tester) async {
      core.demoUi();
      core.dispatch('reply.to:2');
      await layOut(tester, sizes['phone']!);
      expectLaidOut(tester, 'chat replying');

      core.demoUi();
      core.dispatch('edit.start:7');
      await layOut(tester, sizes['phone']!);
      expectLaidOut(tester, 'chat editing');
    });

    testWidgets('lays out with the emoji picker open', (tester) async {
      // 120 emoji in a grid under a message, on a phone.
      core.demoUi();
      core.dispatch('react.open:2');
      await layOut(tester, sizes['phone']!);
      expectLaidOut(tester, 'chat with the picker');
    });

    testWidgets('lays out with the picker showing a whole group',
        (tester) async {
      core.demoUi();
      core.dispatch('react.open:2');
      core.dispatch('emoji.group:Smileys & Emotion');
      await layOut(tester, sizes['cramped']!);
      expectLaidOut(tester, 'chat with a full picker');
    });

    testWidgets('lays out with the overview open', (tester) async {
      core.demoUi();
      core.dispatch('overview.toggle');
      await layOut(tester, sizes['phone']!);
      expectLaidOut(tester, 'chat with the overview');
    });

    testWidgets('lays out with the lightbox open', (tester) async {
      core.demoUi();
      core.dispatch('lightbox:https://example.com/a.png');
      await layOut(tester, sizes['phone']!);
      expectLaidOut(tester, 'chat with the lightbox');
    });

    testWidgets('lays out when scrolled off the present', (tester) async {
      core.demoUi();
      core.dispatch('jump.present');
      await layOut(tester, sizes['phone']!);
      expectLaidOut(tester, 'chat jumping');
    });
  });

  group('the chats list', () {
    for (final entry in sizes.entries) {
      testWidgets('lays out at ${entry.key}', (tester) async {
        core.demoUi();
        core.dispatch('screen.chats');
        await layOut(tester, entry.value);
        expectLaidOut(tester, 'chats at ${entry.key}');
      });
    }

    testWidgets('lays out with a search term in the box', (tester) async {
      core.demoUi();
      core.dispatch('screen.chats');
      core.dispatch('search.change', 'te');
      await layOut(tester, sizes['phone']!);
      expectLaidOut(tester, 'chats searching');
    });
  });

  group('discover and settings', () {
    for (final screen in ['discover', 'settings']) {
      for (final entry in sizes.entries) {
        testWidgets('$screen lays out at ${entry.key}', (tester) async {
          core.demoUi();
          core.dispatch('screen.$screen');
          await layOut(tester, entry.value);
          expectLaidOut(tester, '$screen at ${entry.key}');
        });
      }
    }
  });
}
