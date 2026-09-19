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

import 'package:flutter/gestures.dart';
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

    testWidgets('lays out with a profile open', (tester) async {
      core.demoUi();
      // A guest: no identity to fetch, so the panel says so rather than
      // spinning — and it lays out without a network.
      core.dispatch('profile.open:alice:');
      await layOut(tester, sizes['phone']!);
      expectLaidOut(tester, 'chat with a guest profile');
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

  group('the wheel', () {
    // Laying a screen out was never enough to catch this one: the failure
    // arrives on the first wheel event, not on the first frame. A `Scrollbar`
    // with no controller asks the PrimaryScrollController, and a
    // SingleChildScrollView is only primary on mobile — so on a desktop the
    // scrollbar and the view held different controllers, and every scroll
    // threw "has no ScrollPosition attached".
    Future<void> wheelOver(WidgetTester tester, Finder target) async {
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      pointer.hover(tester.getCenter(target));
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, 60)));
      await tester.pump();
    }

    for (final screen in ['chat', 'chats', 'discover', 'settings']) {
      // The platform has to be said out loud. A widget test runs as Android
      // by default, where a SingleChildScrollView *is* primary and attaches
      // to the very controller the scrollbar is looking at — so this passed
      // on the broken renderer while the desktop app threw on every wheel
      // event. `variant` rather than an override this test resets itself,
      // which the framework catches as a leaked debug variable.
      testWidgets('$screen scrolls without losing its scrollbar',
          variant: TargetPlatformVariant.desktop(), (tester) async {
        core.demoUi();
        if (screen != 'chat') core.dispatch('screen.$screen');
        await layOut(tester, sizes['desktop']!);
        expectLaidOut(tester, '$screen before scrolling');
        final bars = find.byType(Scrollbar);
        expect(bars, findsWidgets, reason: '$screen has nothing to scroll');
        await wheelOver(tester, bars.first);
        expectLaidOut(tester, '$screen on the wheel');
      });
    }
  });

  group('selection', () {
    testWidgets('the whole tree sits in one SelectionArea', (tester) async {
      // One, not one per Text: a selection has to be draggable across the
      // nick, the time and the message, which is most of what anyone wants
      // to copy out of a chat.
      core.demoUi();
      await layOut(tester, sizes['desktop']!);
      expect(find.byType(SelectionArea), findsOneWidget);
      expect(find.text('hello there'), findsOneWidget);
    });

    testWidgets('and taps still reach what is under it', (tester) async {
      // The risk with wrapping everything: a selection gesture that eats the
      // taps underneath. Opening a room from the list is the plainest one.
      core.demoUi();
      core.dispatch('screen.chats');
      await layOut(tester, sizes['desktop']!);
      // The row's "Open", not its name: the name is a label in this list.
      await tester.tap(find.text('Open').first);
      await tester.pump();
      expect(find.text('hello there'), findsWidgets,
          reason: 'tapping the room did not open it');
      expectLaidOut(tester, 'the room the tap opened');
    });
  });

  group('emoji', () {
    // ✏️ is U+270F plus a variation selector asking for emoji presentation,
    // and DejaVu Sans claims U+270F — so ordinary fallback draws a monochrome
    // pencil and never reaches the emoji font. Naming the font is the fix,
    // and this is the assertion that it is still named.
    //
    // Emoji *presentation*, which is narrower than "not a letter". A glyph
    // carrying U+FE0F is asking for it, and so is anything from the emoji
    // blocks. The arrows and crosses on buttons — → ✕ ☰ — are not: they are
    // text glyphs on purpose and take the text font, as does the reply chip's
    // "↩ me: a picture", where the arrow sits in a sentence.

    testWidgets('a lone glyph is drawn in the colour emoji font',
        (tester) async {
      core.demoUi();
      await layOut(tester, sizes['desktop']!);
      final glyphs = tester
          .widgetList<Text>(find.byType(Text))
          .where((t) =>
              t.data != null &&
              RegExp(r'[\ufe0f\u{1f300}-\u{1faff}]', unicode: true)
                  .hasMatch(t.data!));
      expect(glyphs, isNotEmpty, reason: 'the chat screen draws no emoji');
      for (final g in glyphs) {
        expect(g.style?.fontFamilyFallback, contains('Noto Color Emoji'),
            reason: 'a bare glyph without the emoji font: ${g.data}');
      }
    });
  });
}
