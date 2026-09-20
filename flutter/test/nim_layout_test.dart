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
      // The row's "Open", not its name: the name is a label in this list —
      // and the Open belonging to #test, not whichever card is first. There
      // is more than one room in the demo now, and `.first` was a fact about
      // the order they happen to come back in.
      final card = find
          .ancestor(of: find.text('#test'), matching: find.byType(Container))
          .last;
      await tester.tap(find.descendant(of: card, matching: find.text('Open')));
      await tester.pump();
      expect(find.text('hello there'), findsWidgets,
          reason: 'tapping the room did not open it');
      expectLaidOut(tester, 'the room the tap opened');
    });
  });

  group('going to a message', () {
    // The core has always marked the row a reply points at with
    // `scrollHere`, and the renderer ignored the prop — so the arrow on a
    // reply chip highlighted the message and left the view where it was.
    testWidgets('the target is scrolled into view', (tester) async {
      core.demoUi();
      // Short enough that the backlog does not fit, or a scroll has nothing
      // to do and the target is already on screen — which is what the first
      // version of this test proved: the offset stayed at zero because
      // `ensureVisible` was right not to move.
      await layOut(tester, const Size(700, 420));
      final c = tester
          .widget<Scrollable>(find.byType(Scrollable).first)
          .controller!;

      // Away from the present, where the answered message is not.
      c.jumpTo(c.position.maxScrollExtent);
      await tester.pump();
      final before = c.offset;
      expect(before, greaterThan(0.0), reason: 'nothing to scroll here');

      core.dispatch('goto:5');
      await tester.pump(const Duration(milliseconds: 150));
      // Settled, not a timed pump: one pump of 400ms advances the clock but
      // does not run the scroll animation out, and the offset comes back
      // unchanged as though nothing had happened.
      await tester.pumpAndSettle();
      expectLaidOut(tester, 'the backlog after going to a message');
      expect(c.offset, lessThan(before), reason: 'the view did not move');
    });

    testWidgets('and the core is told, so the view is not pinned there',
        (tester) async {
      // A `jumpTo` left set would scroll back to that row on every frame,
      // which is scrolling taken away from the reader.
      core.demoUi();
      await layOut(tester, const Size(700, 420));
      await tester.tap(find.text('→').first);
      await tester.pumpAndSettle();
      expectLaidOut(tester, 'the backlog after the arrow');
      expect(core.dispatchFrame('noop').json.contains('"scrollHere":true'),
          isFalse, reason: 'the core still thinks it has somewhere to go');
    });
  });

  group('jump to present', () {
    // The button only shows when the reader has left the present, and
    // nothing ever said they had: `atPresent` was set true at startup, on
    // opening a room and by the button itself, and false by nobody. So the
    // button was never on screen, which is what "jump to present not
    // working" looked like from outside.
    testWidgets('appears once the backlog is scrolled away from',
        (tester) async {
      core.demoUi();
      await layOut(tester, const Size(700, 420));
      expect(find.text('↓ Jump to present'), findsNothing);

      final c = tester
          .widget<Scrollable>(find.byType(Scrollable).first)
          .controller!;
      c.jumpTo(c.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('↓ Jump to present'), findsOneWidget,
          reason: 'the core was never told the reader had left');
    });

    testWidgets('and takes the view back, and goes away again',
        (tester) async {
      core.demoUi();
      await layOut(tester, const Size(700, 420));
      final c = tester
          .widget<Scrollable>(find.byType(Scrollable).first)
          .controller!;
      c.jumpTo(c.position.maxScrollExtent);
      await tester.pumpAndSettle();

      await tester.tap(find.text('↓ Jump to present'));
      await tester.pumpAndSettle();
      // Reversed, so the present is the zero end.
      expect(c.offset, closeTo(c.position.minScrollExtent, 1.0));
      expect(find.text('↓ Jump to present'), findsNothing);
      expectLaidOut(tester, 'the backlog back at the present');
    });

    testWidgets('and the button fits the cramped window too', (tester) async {
      // It is a row the chat screen did not have before, and every row is
      // height the backlog does not get. At 260 points tall this overflows
      // by a pixel, which is how the first run of these tests failed; the
      // cramped size the rest of the suite uses is the one that has to hold.
      core.demoUi();
      await layOut(tester, sizes['cramped']!);
      final c = tester
          .widget<Scrollable>(find.byType(Scrollable).first)
          .controller!;
      c.jumpTo(c.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('↓ Jump to present'), findsOneWidget);
      expectLaidOut(tester, 'cramped, with the jump button up');
    });

    testWidgets('a settings list has no present to be at', (tester) async {
      // It would be the chat screen's button on the wrong screen's
      // scrolling.
      core.demoUi();
      core.dispatch('screen.settings');
      await layOut(tester, const Size(700, 420));
      final c = tester
          .widget<Scrollable>(find.byType(Scrollable).first)
          .controller!;
      c.jumpTo(c.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('↓ Jump to present'), findsNothing);
      expectLaidOut(tester, 'settings scrolled');
    });
  });

  group('the sender row', () {
    testWidgets('the chips sit against the right edge of the row',
        (tester) async {
      // They used to stop well short of it. The name was `Flexible`, whose
      // flex is 1, so it competed with the `Spacer` beside it for the free
      // space and took half — using the seventy points a name needs and
      // leaving the rest as a hole at the end of the row. Measured, because
      // "right-aligned" was true of the tree and false of the pixels.
      core.demoUi();
      core.dispatch('window.size', '1280x800');
      await layOut(tester, sizes['desktop']!);
      await tester.pump(const Duration(milliseconds: 150));

      // The row the chip is actually in, found by ancestry rather than by
      // index. `Row.at(1)` meant "the second Row in the tree", which is a
      // fact about everything above this one -- it moved the day the header
      // stopped being a Wrap.
      final row = tester.getRect(find
          .ancestor(of: find.text('🙂').first, matching: find.byType(Row))
          .first);
      final chip = tester.getRect(find.text('🙂').first);
      expect(chip.right, greaterThan(row.right - 60),
          reason: 'the chips are ${row.right - chip.right} short of the edge');
      // And the name is still at the left of it, not centred in the slack.
      final name = tester.getRect(find.text('alice').first);
      expect(name.left, lessThan(row.left + 60));
    });
  });

  group('the lightbox', () {
    testWidgets('a picture being looked at covers the conversation',
        (tester) async {
      // It used to be a card in the column with the picture capped at 640 by
      // 480 — a thumbnail-and-a-half below the backlog, off the bottom of a
      // short window, called full size.
      core.demoUi();
      core.dispatch('window.size', '1280x800');
      await layOut(tester, sizes['desktop']!);
      expect(find.text('Picture'), findsNothing);

      core.dispatch('lightbox:https://example.com/a.png');
      await tester.pump(const Duration(milliseconds: 150));
      expectLaidOut(tester, 'the lightbox');
      expect(find.text('Picture'), findsOneWidget);

      // As wide as the conversation it covers, rather than a card in it.
      final pane = tester.getRect(find.text('Picture').first);
      expect(pane.left, lessThan(200));

      core.dispatch('lightbox.close');
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.text('Picture'), findsNothing);
      expectLaidOut(tester, 'the conversation after closing it');
    });
  });

  group('identity', () {
    // Duplicate keys among siblings are an error Flutter throws at build
    // time, so this is mostly a guard on the tree the core emits: every
    // message row names itself now, and two rows must never name themselves
    // the same thing.
    testWidgets('every screen builds with the keys the core gives it',
        (tester) async {
      for (final screen in ['chat', 'chats', 'discover', 'settings']) {
        core.demoUi();
        if (screen != 'chat') core.dispatch('screen.$screen');
        await layOut(tester, sizes['desktop']!);
        expectLaidOut(tester, '$screen with keys');
      }
    });

    testWidgets('a row keeps its element when one above it goes away',
        (tester) async {
      // Hiding the joins and parts takes the system line off the top of the
      // demo backlog, which renumbers every row under it. Keyed by position
      // that is a teardown and rebuild of all of them; keyed by the message
      // it is one row leaving.
      //
      // An arriving line would not show this — it lands at the bottom and
      // renumbers nothing, which is how the first version of this test
      // passed against both.
      core.demoUi();
      await layOut(tester, sizes['desktop']!);
      final before = tester.element(find.text('alice').first);
      core.dispatch('join-part.toggle');
      await tester.pump(const Duration(milliseconds: 150));
      expectLaidOut(tester, 'the backlog with the system lines hidden');
      expect(tester.element(find.text('alice').first), same(before),
          reason: 'the row was torn down rather than kept');
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

  group('the room header', () {
    // "On one line" is a fact about pixels, not about the tree: the tree said
    // hbox all along and Overview was still on a second row.
    Future<void> headerFits(WidgetTester tester, Size size, String what) async {
      core.demoUi();
      await layOut(tester, size);
      final back = tester.getRect(find.text('←').first);
      final people = tester.getRect(find.textContaining('People').first);
      final overview = tester.getRect(find.text('Overview').first);
      expect(people.top, back.top,
          reason: '$what: People is on another line from the back arrow');
      expect(overview.top, back.top,
          reason: '$what: Overview wrapped to its own line');
      expect(overview.right, lessThanOrEqualTo(size.width),
          reason: '$what: Overview runs ${overview.right - size.width} '
              'past the right edge');
    }

    testWidgets('fits on one line on a phone', (tester) async {
      await headerFits(tester, sizes['phone']!, 'phone');
      expectLaidOut(tester, 'the phone header');
    });

    testWidgets('and on a cramped one it wraps rather than overflowing',
        (tester) async {
      // 300 points is narrower than any phone and the three chips do not fit
      // it. What matters there is that the row gives way by wrapping -- the
      // safety net -- instead of painting a control off the edge where it
      // cannot be pressed.
      core.demoUi();
      await layOut(tester, sizes['cramped']!);
      final overview = tester.getRect(find.text('Overview').first);
      expect(overview.right,
          lessThanOrEqualTo(sizes['cramped']!.width),
          reason: 'Overview runs past the right edge of a cramped window');
      expectLaidOut(tester, 'the cramped header');
    });

    testWidgets('a long room name ellipsises rather than pushing a control off',
        (tester) async {
      // The case that made wrapping look necessary. The name is the only
      // element with no upper bound, so it is the one that yields -- and a
      // reader still knows the room from its first few characters, where a
      // control shoved onto a second line costs a row of the backlog.
      core.demoUi();
      core.dispatch('room.open:#a-very-long-channel-name-indeed-for-testing');
      await layOut(tester, sizes['phone']!);
      final overview = tester.getRect(find.text('Overview').first);
      final back = tester.getRect(find.text('←').first);
      expect(overview.top, back.top, reason: 'a long name pushed Overview off');
      expect(overview.right, lessThanOrEqualTo(sizes['phone']!.width));
      expectLaidOut(tester, 'a long room name');
    });
  });

  group('the overview on a phone', () {
    testWidgets('an entry is two lines, not three', (tester) async {
      // The complaint, measured. Each entry was [room, sender, text, →] in a
      // Wrap: on a phone the arrow wrapped to a row of its own, so an entry
      // stood about three lines tall and most of that was a button. Counting
      // rows is unreliable across themes; the height of one entry is not.
      core.demoUi();
      core.dispatch('overview.toggle');
      await layOut(tester, sizes['phone']!);

      // The entry carrying a known line, found by what is in it rather than
      // by position among every InkWell on the screen.
      final entry = find
          .ancestor(
              of: find.textContaining('sandbox-01'),
              matching: find.byType(InkWell))
          .first;
      expect(entry, findsOneWidget, reason: 'the entry is not tappable');

      final h = tester.getRect(entry).height;
      expect(h, lessThan(96),
          reason: 'an overview entry is $h tall — three lines of furniture');

      // The long one, which is what the complaint was actually about: a bot
      // line runs for paragraphs and a summary of it must still be an entry
      // in a list rather than a page of its own.
      final long = find
          .ancestor(
              of: find.textContaining('Result'), matching: find.byType(InkWell))
          .first;
      final lh = tester.getRect(long).height;
      // 167 before the text was clamped, and the clamp is what holds this:
      // a character cap cannot, because it is the font and the width that
      // decide how many lines 96 characters become.
      expect(lh, lessThan(110),
          reason: 'a long line makes a $lh-tall entry');
      expectLaidOut(tester, 'the overview on a phone');
    });


    testWidgets('scrolls, so what is below the fold can be reached',
        (tester) async {
      // It did not. The pane drew its entries and whatever did not fit was
      // simply unreachable -- which is why there were only ever eight.
      core.demoUi();
      core.dispatch('overview.toggle');
      await layOut(tester, sizes['phone']!);

      final list = find
          .ancestor(
              of: find.textContaining('sandbox-01'),
              matching: find.byType(Scrollable))
          .first;
      expect(list, findsOneWidget, reason: 'the overview is not scrollable');

      final pos = tester.widget<Scrollable>(list).controller!.position;
      expect(pos.maxScrollExtent, greaterThan(0),
          reason: 'the overview has nothing below the fold to scroll to');

      pos.jumpTo(pos.maxScrollExtent);
      await tester.pumpAndSettle();
      expectLaidOut(tester, 'the overview scrolled to its end');
    });
    testWidgets('and the whole entry is the control, not an arrow',
        (tester) async {
      core.demoUi();
      core.dispatch('overview.toggle');
      await layOut(tester, sizes['phone']!);
      // Scoped to the overview: a `→` also jumps to the line a reply
      // answers, up in the backlog, and that one is not this one.
      final card = find
          .ancestor(
              of: find.textContaining('sandbox-01'), matching: find.byType(InkWell))
          .first;
      expect(find.descendant(of: card, matching: find.text('→')), findsNothing,
          reason: 'the arrow button is back');
    });
  });

  group('a field holding an identifier', () {
    testWidgets('asks the keyboard for no help at all', (tester) async {
      // A phone keyboard puts a space after a full stop, because a full stop
      // ends a sentence — and is also the middle of `alice.bsky.social`.
      // These are the properties that turn that off; the tree carrying a
      // `verbatim` prop proves nothing if the renderer drops it.
      core.dispatch('screen.connect');
      core.dispatch('auth.mode:bluesky');
      await layOut(tester, sizes['phone']!);

      final fields = tester.widgetList<TextField>(find.byType(TextField));
      expect(fields, isNotEmpty);
      for (final f in fields) {
        expect(f.autocorrect, isFalse, reason: 'autocorrect is on');
        expect(f.enableSuggestions, isFalse, reason: 'suggestions are on');
        expect(f.textCapitalization, TextCapitalization.none);
        expect(f.keyboardType, TextInputType.url);
      }
      expectLaidOut(tester, 'the connect fields');
    });
  });
}
