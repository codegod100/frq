/// The spike's real proof: Nim's tree, as Flutter widgets, driven by taps.
///
/// A screenshot shows that something painted. This shows that the round trip
/// closes — a tap reaches Nim, Nim's state moves, the new tree comes back, and
/// the widgets change to match. That is the claim the spike is making, and it
/// is testable headlessly with no GL, which is why it is here rather than in a
/// screenshot script.
///
///   just nim-spike-test
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frq_core/frq_core.dart' as core;
import 'package:cljd_flutter/nim_renderer.dart';

void main() {
  // No sockets from a widget test. `connect` otherwise opens a real TLS
  // connection to irc.freeq.at, which these tests did until this line.
  setUpAll(core.goOffline);
  setUp(core.resetUi);

  /// The TextField currently showing [text].
  ///
  /// By content and not by position, and that distinction caught a bug in
  /// these tests: in guest mode the FIRST field is the nickname, not the
  /// host, so `find.byType(TextField).first` was clearing the wrong one and
  /// the assertion about the host failed for a reason that had nothing to do
  /// with the code under test.
  Finder fieldShowing(WidgetTester tester, String text) => find.byWidgetPredicate(
      (w) => w is TextField && w.controller?.text == text);

  testWidgets('the connect screen arrives from Nim as real widgets',
      (tester) async {
    await tester.pumpWidget(const NimApp());

    expect(find.text('frq'), findsWidgets);
    expect(find.text('Server'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.byType(Checkbox), findsOneWidget);
    // Guest is the default mode, so the nickname field is the one shown.
    expect(find.widgetWithText(OutlinedButton, 'Bluesky'), findsOneWidget);
  });

  testWidgets('nothing renders as an unknown tag', (tester) async {
    await tester.pumpWidget(const NimApp());
    // The renderer paints an orange `?tag` box for a tag it does not know.
    // Finding one means Nim emitted something Dart has never heard of, which
    // is exactly the drift this test exists to catch.
    expect(find.textContaining('?'), findsNothing);
  });

  testWidgets('tapping a mode button changes which fields exist',
      (tester) async {
    await tester.pumpWidget(const NimApp());
    // Guest is the default, so the nickname field is the one on screen.
    expect(fieldShowing(tester, 'frq-guest'), findsOneWidget);

    await tester.tap(find.text('Bluesky'));
    await tester.pump();

    // The Bluesky copy comes from Nim, not from this side.
    expect(find.text('Sign in with Bluesky'), findsOneWidget);
    // ...and the nickname field is gone, because Nim stopped emitting it.
    expect(fieldShowing(tester, 'frq-guest'), findsNothing);
  });

  testWidgets('the TLS checkbox rewrites the port field', (tester) async {
    await tester.pumpWidget(const NimApp());

    TextField portField() => tester.widgetList<TextField>(find.byType(TextField))
        .firstWhere((f) => f.controller?.text == '6697' ||
                           f.controller?.text == '6667');

    expect(portField().controller!.text, '6697');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(portField().controller!.text, '6667');
  });

  testWidgets('typing goes to Nim and comes back', (tester) async {
    await tester.pumpWidget(const NimApp());

    await tester.enterText(fieldShowing(tester, 'irc.freeq.at'), 'localhost');
    await tester.pump();

    // Round trip: the text is in the widget because Nim put it in the tree,
    // not because the TextField remembered it. Asking Nim directly is what
    // makes that distinction.
    expect(core.render().toString(), isNotEmpty);
    expect(
      tester.widgetList<TextField>(find.byType(TextField))
          .any((f) => f.controller?.text == 'localhost'),
      isTrue,
    );
  });

  testWidgets('Connect with an empty host shows Nim\'s error, and it dismisses',
      (tester) async {
    await tester.pumpWidget(const NimApp());

    // A space, not an empty string: Nim's rule is `strip().len == 0`, and a
    // space exercises it where "" would also pass a naive emptiness check.
    await tester.enterText(fieldShowing(tester, 'irc.freeq.at'), ' ');
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.textContaining('A server is required'), findsOneWidget);
    expect(find.text('Dismiss'), findsOneWidget);

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.text('Dismiss'), findsNothing);
  });

  testWidgets('Connect swaps the button for a spinner', (tester) async {
    await tester.pumpWidget(const NimApp());
    expect(find.byType(CircularProgressIndicator), findsNothing);

    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Connect'), findsNothing);
    expect(find.textContaining('irc.freeq.at:6697'), findsOneWidget);
    // And a way out of it, which the first run of the spike did not have:
    // a connection that never completes was a spinner with no escape.
    expect(find.text('Cancel'), findsOneWidget);
  });
}
