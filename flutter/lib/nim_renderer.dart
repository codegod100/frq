/// The renderer: a Nim widget tree, walked into Flutter widgets.
///
/// This is the Dart half of the spike's claim. It knows the tag vocabulary
/// and nothing else — no screens, no state, no idea what "connect" means. Nim
/// decides what the screen is; this decides what a `vbox` looks like.
///
/// The measure of whether the split is honest is how boring this file is. If
/// a feature ever needs a change here AND in Nim, the boundary is in the
/// wrong place.
import 'package:flutter/material.dart';
import 'package:frq_core/frq_core.dart' as core;

/// Rebuilds from Nim on every event. One `setState` per dispatch, and the
/// whole tree is rebuilt — which is what Flutter does anyway, and is why the
/// Nim side does not need a reconciler of its own.
class NimApp extends StatefulWidget {
  const NimApp({super.key});
  @override
  State<NimApp> createState() => _NimAppState();
}

class _NimAppState extends State<NimApp> {
  late core.UiNode _tree = core.render();

  // One controller per keyed entry, kept across rebuilds.
  //
  // This is the whole reason `:key` is on every entry in both the Clojure and
  // the Nim: a controller identified by position instead of name meant the
  // host field and the port field shared one and both showed the port. The
  // comment survives three languages now.
  final _controllers = <String, TextEditingController>{};

  void _send(String id, [String value = '']) =>
      setState(() => _tree = core.dispatch(id, value));

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'frq',
        theme: ThemeData.dark(useMaterial3: true),
        home: Scaffold(
          body: SafeArea(child: SingleChildScrollView(child: _build(_tree))),
        ),
      );

  Widget _build(core.UiNode n) {
    final kids = n.children.map(_build).toList();

    switch (n.tag) {
      case 'page':
        return Center(
          child: ConstrainedBox(
            constraints:
                BoxConstraints(maxWidth: n.prop('maxWidth', 520).toDouble()),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: kids),
            ),
          ),
        );

      case 'vbox':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _spaced(kids, n.prop('spacing', 0), vertical: true),
        );

      case 'hbox':
        // Wrap and not Row, and this was a bug before it was a decision: the
        // three mode buttons are wider than the 520-point page, and a Row
        // answers that with a RenderFlex overflow rather than a second line.
        // A `:hbox` in the screens means "these go together across", not "these
        // fit"; the tree has no idea how wide the window is and should not.
        final gap = n.prop('spacing', 0).toDouble();
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: kids,
        );

      case 'card':
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: kids),
          ),
        );

      case 'title':
        return Text(n.prop('label', ''),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold));

      case 'title-2':
        return Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(n.prop('label', ''),
              style:
                  const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        );

      case 'label':
        return Text(n.prop('label', ''));

      case 'dim-label':
        return Opacity(
            opacity: 0.7,
            child: Text(n.prop('label', ''),
                style: const TextStyle(fontSize: 12)));

      case 'spinner':
        return const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2));

      case 'button':
        final onClick = n.prop('onClick', '');
        final label = Text(n.prop('label', ''));
        // No padding of its own: spacing belongs to the container, which is
        // the only thing that knows whether this is in a row or a column.
        return n.prop('kind', 'default') == 'primary'
            ? FilledButton(onPressed: () => _send(onClick), child: label)
            : OutlinedButton(onPressed: () => _send(onClick), child: label);

      case 'checkbutton':
        return Row(mainAxisSize: MainAxisSize.min, children: [
          Checkbox(
            value: n.prop('active', false),
            onChanged: (_) => _send(n.prop('onToggled', '')),
          ),
          Text(n.prop('label', '')),
        ]);

      case 'entry':
        final key = n.prop('key', '');
        final text = n.prop('text', '');
        final c = _controllers.putIfAbsent(
            key, () => TextEditingController(text: text));
        // Only when it actually differs: assigning unconditionally moves the
        // caret to the end on every keystroke, which is the classic way to
        // make a controlled text field unusable.
        if (c.text != text) {
          c.value = c.value.copyWith(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          );
        }
        final field = TextField(
          controller: c,
          decoration: InputDecoration(
            hintText: n.prop('placeholder', ''),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (v) => _send(n.prop('onChange', ''), v),
        );
        final w = n.prop('widthRequest', 0);
        // A width request is a minimum in the screens' vocabulary, but here it
        // has to be a maximum too: an unconstrained TextField inside a Wrap
        // has no width at all to take.
        return w > 0 ? SizedBox(width: w.toDouble(), child: field) : field;

      default:
        // An unknown tag paints as itself rather than crashing or vanishing.
        // Nim can add one and see it before this file has heard of it, which
        // is the behaviour that makes the boundary pleasant to work across.
        return Container(
          padding: const EdgeInsets.all(4),
          color: Colors.orange.withValues(alpha: 0.3),
          child: Text('?${n.tag}'),
        );
    }
  }

  List<Widget> _spaced(List<Widget> kids, num gap, {required bool vertical}) {
    if (gap <= 0 || kids.length < 2) return kids;
    final out = <Widget>[];
    for (var i = 0; i < kids.length; i++) {
      if (i > 0) {
        out.add(vertical
            ? SizedBox(height: gap.toDouble())
            : SizedBox(width: gap.toDouble()));
      }
      out.add(kids[i]);
    }
    return out;
  }
}
