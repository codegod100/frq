/// The renderer: a Nim widget tree, walked into Flutter widgets.
///
/// This knows the tag vocabulary and nothing else — no screens, no state, no
/// idea what "connect" means. Nim decides what the screen is; this decides
/// what a `vbox` looks like.
///
/// The measure of whether the split is honest is how boring this file is. If a
/// feature ever needs a change here AND in Nim, the boundary is in the wrong
/// place. The treatments are `flutter/src/frq/hiccup.cljd`'s, so a tree from
/// Nim paints the way the same tree painted under ClojureDart.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';

import 'package:flutter/material.dart';
import 'package:frq_core/frq_core.dart' as core;

import 'nim_theme.dart' as t;

class NimApp extends StatefulWidget {
  const NimApp({super.key});
  @override
  State<NimApp> createState() => _NimAppState();
}

class _NimAppState extends State<NimApp> {
  late core.UiFrame _frame = core.renderFrame();
  core.UiNode get _tree => _frame.tree;
  Timer? _poll;

  // One controller and one focus node per keyed entry, kept across rebuilds.
  //
  // This is why `:key` is on every entry in both the Clojure and the Nim: a
  // controller identified by position instead of name meant the host field and
  // the port field shared one and both showed the port. The focus node is the
  // same bug one layer up — the field is rebuilt from a fresh tree on every
  // keystroke, so without a node held per key the caret goes nowhere after the
  // first line.
  final _controllers = <String, TextEditingController>{};
  final _focus = <String, FocusNode>{};

  // One tap recogniser per link URL, kept across rebuilds and disposed with
  // the state. A recogniser made during build and dropped on the next frame
  // leaks, and this tree is rebuilt on every keystroke.
  final _linkTaps = <String, TapGestureRecognizer>{};

  @override
  void initState() {
    super.initState();
    // Polling, because the socket lives on a Nim thread and there is no
    // callback into Dart. At ~70µs a render a 100ms timer costs nothing.
    _poll = Timer.periodic(const Duration(milliseconds: 100), (_) {
      // Compared as the JSON Nim already produced, and decoded only when it
      // differs. Stringifying both trees to answer "did anything change" was
      // ~1MB of string churn per poll in a busy room, ten times a second, for
      // an answer that is almost always no.
      final next = core.pollIfChanged(_frame.json);
      if (next != null) setState(() => _frame = next);
    });
  }

  void _send(String id, [String value = '']) {
    if (id.isEmpty) return;
    setState(() => _frame = core.dispatchFrame(id, value));
    if (id == 'send') _focus['draft']?.requestFocus();
  }

  @override
  void dispose() {
    _poll?.cancel();
    for (final c in _controllers.values) {
      c.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    for (final r in _linkTaps.values) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'frq',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: t.bg,
          colorScheme: const ColorScheme.dark(
            primary: t.accent,
            onPrimary: t.onAccent,
            surface: t.bg,
            onSurface: t.onBg,
            error: t.destructive,
          ),
        ),
        home: Scaffold(backgroundColor: t.bg, body: SafeArea(child: _build(_tree))),
      );

  // ---------------------------------------------------------------- helpers

  TextStyle _style(double size, Color color) =>
      TextStyle(fontSize: size, color: color, height: 1.35);

  double _d(dynamic v, double fallback) =>
      v is num ? v.toDouble() : fallback;

  /// Gaps between children, as real widgets rather than a `spacing:` — the
  /// same layout on every Flutter version this might be built against.
  List<Widget> _spaced(List<Widget> kids, double gap, {required bool vertical}) {
    if (gap <= 0 || kids.length < 2) return kids;
    final out = <Widget>[];
    for (var i = 0; i < kids.length; i++) {
      if (i > 0) {
        out.add(vertical ? SizedBox(height: gap) : SizedBox(width: gap));
      }
      out.add(kids[i]);
    }
    return out;
  }

  /// A source that may be a bundled asset, a file on disk, or a URL — the
  /// three the screens hand over, named apart by an `asset:` prefix so they
  /// stay one property.
  ImageProvider? _imageProvider(String src) {
    if (src.isEmpty) return null;
    if (src.startsWith('asset:')) return AssetImage(src.substring(6));
    if (src.startsWith('http://') || src.startsWith('https://')) {
      return NetworkImage(src);
    }
    return FileImage(File(src));
  }

  Widget _wrapTap(String onClick, Widget child, {BorderRadius? radius}) {
    if (onClick.isEmpty) return child;
    return InkWell(
      onTap: () => _send(onClick),
      borderRadius: radius,
      child: child,
    );
  }

  // ------------------------------------------------------------------ build

  /// The axis of the widget a node is being built *into*, because `Expanded`
  /// is only legal inside a Flex and there is no way to ask Flutter after the
  /// fact.
  ///
  /// Getting this wrong is what "Cannot hit test a render box that has never
  /// been laid out" means, in a pile: an `Expanded` inside a `Wrap` fails the
  /// layout, and every box under it is then asked to hit-test without ever
  /// having been laid out. The chats screen did exactly that — two unsized
  /// entries in an `hbox`, which is a Wrap.
  /// What an unsized entry or a stranded scroll falls back to.
  ///
  /// Both are only reachable when the tree has put one outside a Flex, which
  /// is a tree bug rather than a rendering choice. The numbers exist so that
  /// bug renders as something a person can see and a test can catch, not so
  /// that it renders correctly.
  static const _unsizedEntry = 320.0;
  static const _strandedScroll = 400.0;

  static const _noAxis = '';
  static const _row = 'row';
  static const _column = 'column';

  Widget _build(core.UiNode n, [String axis = _noAxis]) {
    final spacing = _d(n.props['spacing'], 0);
    final flex = axis == _row || axis == _column;

    // What this node's own children are being built into.
    final childAxis = switch (n.tag) {
      'page' || 'vbox' || 'card' || 'scroll' || 'dialog' => _column,
      // Wrapping unless the row says otherwise. Flipping this default was
      // tried and reverted: only 4 of 15 `hbox` call sites state `wrap` at
      // all, so the other 11 became Rows and overflowed — the tree's habit is
      // to wrap, and the default has to match it.
      'hbox' => n.prop('wrap', true) ? _noAxis : _row,
      _ => _noAxis,
    };
    // A paragraph's children are spans, not widgets — building them as
    // widgets and throwing them away is what the `inline` special case did.
    final kids = n.tag == 'paragraph'
        ? const <Widget>[]
        : n.children.map((c) => _build(c, childAxis)).toList();

    // One rule for "take the remaining main-axis extent", stated by the node
    // that expands. It used to be three: a vbox prop, a scroll with no
    // height, and a row peering at its children's props to infer it.
    Widget expanded(Widget w) =>
        (n.prop('expand', false) && flex) ? Expanded(child: w) : w;

    switch (n.tag) {
      case 'page':
        return SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: _d(n.props['maxWidth'], 520)),
              child: Padding(
                padding: const EdgeInsets.all(t.spaceM),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _spaced(kids, spacing, vertical: true)),
              ),
            ),
          ),
        );

      case 'vbox':
        {
          Widget col = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: _spaced(kids, spacing, vertical: true),
          );
          col = _margins(n, col);
          final w = _d(n.props['widthRequest'], 0);
          if (w > 0) col = SizedBox(width: w, child: col);
          return expanded(col);
        }

      // Prose with links in it. NOT a Wrap: children of a Wrap are given
      // unbounded width, so a long URL or a long word can never wrap — it
      // overflows, the layout fails, and every box under it is then hit-tested
      // having never been laid out. Spans in one RichText wrap properly.
      case 'paragraph':
        return Text.rich(
          TextSpan(children: n.children.map(_span).toList()),
          softWrap: true,
        );

      case 'hbox':
        {
          // Wrap and not Row: `:hbox` in the screens means "these go together
          // across", not "these fit". The head row of the chat screen asks for
          // more than 360 points has, and a Row answers that with an overflow
          // rather than a second line.
          final wrapping = n.prop('wrap', true);
          final align = n.prop('align', 'center');
          if (!wrapping) {
            // An expanding row stretches on its cross axis, which is where a
            // child's height comes from — Expanded in a Row is about width.
            // Stretch needs a bounded height, and `expanded()` below is what
            // gives the row one; without it the stretch resolves to infinity.
            final fills = n.prop('expand', false);
            final row = Row(
              crossAxisAlignment: fills
                  ? CrossAxisAlignment.stretch
                  : (align == 'end'
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.center),
              children: _spaced(kids, spacing, vertical: false),
            );
            return expanded(_margins(n, row));
          }
          return _margins(
            n,
            Wrap(
              spacing: spacing,
              runSpacing: spacing,
              crossAxisAlignment: align == 'end'
                  ? WrapCrossAlignment.end
                  : WrapCrossAlignment.center,
              children: kids,
            ),
          );
        }

      // Container::Card in the Clojure: padding 12, fills its width.
      case 'card':
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: t.spaceXxxs),
          padding: const EdgeInsets.all(t.spaceXs),
          decoration: BoxDecoration(
            color: t.card,
            borderRadius: BorderRadius.circular(t.radiusS),
          ),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: _spaced(kids, spacing > 0 ? spacing : t.spaceXxs,
                  vertical: true)),
        );

      case 'title':
        return Text(n.prop('label', ''),
            style: _style(t.textTitle3, t.onBg)
                .copyWith(fontWeight: FontWeight.bold));

      case 'title-2':
        return Padding(
          padding: const EdgeInsets.only(top: t.spaceXxs, bottom: t.spaceXxxs),
          child: Text(n.prop('label', ''),
              style: _style(t.textTitle4, t.onBg)
                  .copyWith(fontWeight: FontWeight.w600)),
        );

      case 'label':
        return Text(n.prop('label', ''), style: _style(t.textBody, t.onBg));

      case 'dim-label':
        return Text(n.prop('label', ''), style: _style(t.textCaption, t.dim));

      /// Prose, as opposed to a label: this is what a message is, and it
      /// wraps. Kept apart from `label` because a wrapping label in a row
      /// lays out against the row's width rather than the column's.
      case 'text':
        return Text(n.prop('text', ''), style: _style(t.textBody, t.onBg));

      case 'link':
        return _wrapTap(
          n.prop('onClick', ''),
          Text(
            n.prop('label', ''),
            style: _style(t.textBody, t.accent)
                .copyWith(decoration: TextDecoration.underline,
                          decorationColor: t.accent),
          ),
        );

      case 'separator':
        return const Divider(height: 1, thickness: 1, color: t.divider);

      case 'spacer':
        {
          final s = _d(n.props['size'], t.spaceXxs);
          return SizedBox(width: s, height: s);
        }

      case 'spinner':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: t.accent)),
            if (n.prop('label', '').isNotEmpty) ...[
              const SizedBox(width: t.spaceXxs),
              Text(n.prop('label', ''), style: _style(t.textCaption, t.dim)),
            ],
          ],
        );

      /// A dot that says whether the thing is live, and the words beside it.
      case 'status':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                color: n.prop('live', false) ? t.success : t.dim,
                borderRadius: BorderRadius.circular(t.radiusXs),
              ),
            ),
            const SizedBox(width: 6),
            Text(n.prop('label', ''), style: _style(t.textCaption, t.dim)),
          ],
        );

      case 'button':
        {
          final onClick = n.prop('onClick', '');
          final kind = n.prop('kind', 'default');
          final label = Text(n.prop('label', ''));
          if (kind == 'primary') {
            return FilledButton(
                onPressed: () => _send(onClick), child: label);
          }
          if (kind == 'destructive') {
            return FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor: t.destructive,
                  foregroundColor: t.onDestructive),
              onPressed: () => _send(onClick),
              child: label,
            );
          }
          return OutlinedButton(onPressed: () => _send(onClick), child: label);
        }

      case 'checkbutton':
        {
          // The label is part of the target. 20 logical pixels is a fine tick
          // on a desktop pointer and a miss on a thumb, so the whole row taps.
          final onToggled = n.prop('onToggled', '');
          return InkWell(
            onTap: () => _send(onToggled),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Checkbox(
                  value: n.prop('active', false),
                  onChanged: (_) => _send(onToggled),
                ),
                // Flexible, because the label is prose and the row is as wide
                // as the window: "Hide join/part messages" beside a checkbox
                // overflows a phone otherwise.
                Flexible(
                  child: Text(n.prop('label', ''),
                      style: _style(t.textBody, t.onBg)),
                ),
              ],
            ),
          );
        }

      case 'emoji':
        return _wrapTap(
          n.prop('onClick', ''),
          Text(n.prop('glyph', n.prop('emoji', '')),
              style: TextStyle(fontSize: _d(n.props['size'], 16))),
        );

      /// A reaction pill: the glyph, and the tally beside it where there is
      /// one to show. The same shape whether it is a reaction under a message,
      /// a swatch in the picker, or a chip on the sender's row — which is the
      /// point: what you press to react and what appears once you have should
      /// look like one family.
      ///
      /// A count of zero is no count. The picker passes 0 for every swatch,
      /// and a grid of little grey zeroes is noise where a reader is scanning
      /// for a face. `mine` is the accent, because the only thing a pill has
      /// to say at a glance is whether pressing it again takes yours off.
      case 'reaction':
        {
          final size = _d(n.props['size'], 14);
          final count = n.prop('count', 0);
          final mine = n.prop('mine', false);
          final pad = (0.25 * size).clamp(2.0, 8.0);
          return _wrapTap(
            n.prop('onClick', ''),
            Container(
              padding: EdgeInsets.symmetric(horizontal: pad, vertical: pad / 2),
              decoration: BoxDecoration(
                color: mine ? t.accent : t.component,
                borderRadius: BorderRadius.circular(t.radiusS),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(n.prop('emoji', ''), style: TextStyle(fontSize: size)),
                  if (count > 0) ...[
                    const SizedBox(width: 4),
                    Text('$count',
                        style: _style(t.textCaption,
                            mine ? t.onAccent : t.dim)),
                  ],
                ],
              ),
            ),
          );
        }

      /// A face is a way in to who someone is, so it takes the press that
      /// opens their profile. A picture that will not load is a face that
      /// stays its initial and nothing else.
      case 'avatar':
        {
          final size = _d(n.props['size'], 32);
          final provider = _imageProvider(n.prop('url', ''));
          final fallback = n.prop('fallback', '');
          final face = CircleAvatar(
            radius: size / 2,
            backgroundColor: t.component,
            backgroundImage: provider,
            onBackgroundImageError: provider == null ? null : (_, _) {},
            child: provider == null
                ? Text(
                    fallback.isNotEmpty
                        ? fallback.substring(0, 1).toUpperCase()
                        : '?',
                    style: _style(t.textBody, t.onBg))
                : null,
          );
          final onClick = n.prop('onClick', '');
          if (onClick.isEmpty) return face;
          return InkWell(
            onTap: () => _send(onClick),
            customBorder: const CircleBorder(),
            child: face,
          );
        }

      case 'image':
        {
          final provider = _imageProvider(n.prop('src', ''));
          if (provider == null) return const SizedBox.shrink();
          final maxW = _d(n.props['maxWidth'], 0);
          final maxH = _d(n.props['maxHeight'], 0);
          Widget img = Image(
            image: provider,
            fit: BoxFit.contain,
            // A half-written cache file, or one deleted under us: the decoder
            // throws during the build, and an exception in a build is a red
            // screen for the whole conversation rather than a gap where one
            // picture was.
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          );
          if (maxW > 0 || maxH > 0) {
            img = ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxW > 0 ? maxW : double.infinity,
                maxHeight: maxH > 0 ? maxH : double.infinity,
              ),
              child: img,
            );
          }
          return _wrapTap(n.prop('onClick', ''), img);
        }

      case 'entry':
        {
          final key = n.prop('key', '');
          final value = n.prop('text', '');
          final c = _controllers.putIfAbsent(
              key, () => TextEditingController(text: value));
          // Only when it actually differs: assigning unconditionally moves the
          // caret to the end on every keystroke.
          if (c.text != value) {
            c.value = c.value.copyWith(
              text: value,
              selection: TextSelection.collapsed(offset: value.length),
            );
          }
          final field = TextField(
            controller: c,
            focusNode: _focus.putIfAbsent(key, FocusNode.new),
            style: _style(t.textBody, t.onBg),
            decoration: InputDecoration(
              hintText: n.prop('placeholder', ''),
              hintStyle: _style(t.textBody, t.dim),
              isDense: true,
              filled: true,
              fillColor: t.component,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(t.radiusS),
                borderSide: BorderSide.none,
              ),
            ),
            onChanged: (v) => _send(n.prop('onChange', ''), v),
            onSubmitted: (_) => _send(n.prop('onSubmit', '')),
          );
          final w = _d(n.props['widthRequest'], 0);
          if (w > 0) return SizedBox(width: w, child: field);
          // No width asked for: take the rest of the row where there is a row
          // to take it from, and otherwise a definite width. NOT Expanded
          // unconditionally — a TextField has no intrinsic width, so in a Wrap
          // it is both illegal and unmeasurable, and that combination is what
          // took the whole screen down rather than one field.
          return axis == _row
              ? Expanded(child: field)
              : SizedBox(width: _unsizedEntry, child: field);
        }

      case 'scroll':
        {
          Widget body = SingleChildScrollView(
            // The backlog reads from the bottom; a settings list from the top.
            reverse: n.prop('stickToBottom', false),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _spaced(kids, spacing, vertical: true)),
          );
          body = Scrollbar(child: body);
          // A scroll takes what the column has left. Outside a Flex there is
          // nothing to take, and the tree is malformed — `_strandedScroll` is
          // a visible size rather than a correct one, so the layout tests see
          // a screen instead of an exception.
          return flex
              ? Expanded(child: body)
              : const SizedBox(height: _strandedScroll);
        }

      /// A panel over the screen rather than a screen of its own.
      case 'dialog':
        return Card(
          color: t.cardComponent,
          child: Padding(
            padding: const EdgeInsets.all(t.spaceS),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (n.prop('title', '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: t.spaceXxs),
                    child: Text(n.prop('title', ''),
                        style: _style(t.textTitle4, t.onCard)
                            .copyWith(fontWeight: FontWeight.w600)),
                  ),
                ..._spaced(kids, spacing, vertical: true),
              ],
            ),
          ),
        );

      default:
        // An unknown tag paints as itself rather than crashing or vanishing.
        // Nim can add one and see it before this file has heard of it, which
        // is what makes the boundary pleasant to work across.
        return Container(
          padding: const EdgeInsets.all(4),
          color: Colors.orange.withValues(alpha: 0.3),
          child: Text('?${n.tag}'),
        );
    }
  }

  /// One node of an inline paragraph, as a span.
  ///
  /// Only `text` and `link` appear here — they are the only things `runNodes`
  /// emits — and anything else falls back to its plain text so an unexpected
  /// tag degrades to something readable rather than vanishing.
  InlineSpan _span(core.UiNode n) {
    switch (n.tag) {
      case 'link':
        final url = n.prop('url', n.prop('label', ''));
        final onClick = n.prop('onClick', '');
        return TextSpan(
          text: n.prop('label', ''),
          style: _style(t.textBody, t.accent)
              .copyWith(decoration: TextDecoration.underline,
                        decorationColor: t.accent),
          recognizer: onClick.isEmpty
              ? null
              : (_linkTaps[url] ??= TapGestureRecognizer()
                ..onTap = () => _send(onClick)),
        );
      case 'text':
        return TextSpan(
            text: n.prop('text', ''), style: _style(t.textBody, t.onBg));
      default:
        return TextSpan(
            text: n.prop('label', n.prop('text', '')),
            style: _style(t.textBody, t.onBg));
    }
  }

  /// `margin` and its four sides — the props the
  /// screens use to buy air without a wrapper each time.
  Widget _margins(core.UiNode n, Widget child) {
    final all = _d(n.props['margin'], 0);
    final top = _d(n.props['marginTop'], all);
    final bottom = _d(n.props['marginBottom'], all);
    final right = _d(n.props['marginRight'], all);
    final left = _d(n.props['marginLeft'], all);
    if (top == 0 && bottom == 0 && right == 0 && left == 0) return child;
    return Padding(
      padding: EdgeInsets.only(
          top: top, bottom: bottom, right: right, left: left),
      child: child,
    );
  }
}
