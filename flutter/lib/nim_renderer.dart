/// The renderer: a Nim widget tree, walked into Flutter widgets.
///
/// This knows the tag vocabulary and nothing else — no screens, no state, no
/// idea what "connect" means. Nim decides what the screen is; this decides
/// what a `vbox` looks like.
///
/// The measure of whether the split is honest is how boring this file is. If a
/// feature ever needs a change here AND in Nim, the boundary is in the wrong
/// place.
///
/// The widgets are flatkit's (github.com/codegod100/flutterkit): flat, with
/// hover and press that change colour on the spot and nothing that ripples,
/// fades or slides. Material is left only where flatkit has nothing of its
/// own — text editing, selection and scrollbars — and `KitTheme.material`
/// turns its splashes and highlights off.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flatkit/flatkit.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frq_core/frq_core.dart' as core;
import 'src/host.dart' as host;

import 'nim_theme.dart' as t;

/// A child of an `overlay` that covers it rather than floating at its foot.
///
/// A widget rather than a flag, because the thing that has to act on it is
/// the `Stack` two levels up, and a tree is the only channel between them.
/// It is never built: the overlay unwraps it and uses `child`.
class _Filling extends StatelessWidget {
  const _Filling(this.child);
  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

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

  // One ScrollController per `scrollKey`, for the same reason the entries
  // have one per key — and for a second reason of its own. A `Scrollbar` with
  // no controller of its own asks the PrimaryScrollController, and a
  // SingleChildScrollView is only primary on mobile: on a desktop the two
  // ends looked at different controllers, so the first wheel event over any
  // scroll threw "The Scrollbar's ScrollController has no ScrollPosition
  // attached" and went on throwing it. Naming the controller joins them.
  //
  // Two positions must never share one, which is what makes `scrollKey` a
  // requirement rather than a nicety — the chat screen's is per room, since
  // switching rooms is a different backlog at a different offset.
  final _scrollers = <String, ScrollController>{};

  // The last size reported to the core, so a rebuild that changed nothing
  // does not dispatch.
  int _reportedW = 0;
  int _reportedH = 0;

  // Where a "go to that message" is pointing, for the one frame it is
  // pointing there. The core marks the row with `scrollHere`, this finds it
  // after the frame is laid out — `ensureVisible` needs a built element, so
  // it cannot happen during the build that asks for it — and then tells the
  // core it has arrived, which takes the mark off. Leaving it on would pin
  // the view to that row and take scrolling away from the reader.
  final _jumpKey = GlobalKey();

  // The last `scrollToBottom` tick acted on, per scroll. The core counts up
  // when "Jump to present" is pressed; an unchanged count is a frame where
  // nobody asked to be moved.
  final _bottomTicks = <String, int>{};

  // Whether each scroll is at the present, as last reported to the core.
  // Only the changes are sent: a notification arrives per pixel of a drag,
  // and the core has one question, not a thousand.
  final _atPresent = <String, bool>{};

  // The colours of the frame being built, read once from `KitTheme` at the
  // top of the build so every case below can reach them without a context.
  KitColors _c = t.frqDark;

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

      // A picture the reader asked for. Polled beside the tree because it is
      // the same question — "has the core asked for anything?" — and because
      // a file dialog cannot be opened from inside a build.
      final want = core.wantedPicture();
      if (want.isNotEmpty) _pickPicture(want);
    });
  }

  /// Choose a picture, upload it, and tell the core where it landed.
  ///
  /// Both halves are the platform's: a file dialog and a multipart POST. The
  /// core knows who is asking and where to, and nothing else about it.
  Future<void> _pickPicture(String want) async {
    final j = jsonDecode(want) as Map<String, dynamic>;
    try {
      final url = await host.pickAndUpload(
        host: j['host'] as String? ?? '',
        did: j['did'] as String? ?? '',
        channel: j['channel'] as String? ?? '',
        source: j['source'] as String? ?? 'file',
      );
      if (!mounted) return;
      // An empty URL is the reader closing the dialog, which is not a
      // failure and should not be reported as one.
      _send(url.isEmpty ? 'attachment.failed' : 'attachment.ready:$url');
    } catch (e) {
      if (mounted) _send('attachment.failed:$e');
    }
  }

  /// An entry that also takes a pasted picture, sending [event] when one is.
  ///
  /// The paste is watched, not taken over: the key goes on to the field and
  /// pastes whatever text there is, and the clipboard is asked beside it
  /// whether it holds a picture. A clipboard holding a picture holds no text
  /// to paste, so the two never both happen — and a paste of text never waits
  /// on a question about pictures.
  ///
  /// A browser never asks here: a picture pasted into a page arrives as the
  /// page's `paste` event, which `frq_host.js` listens for.
  Widget _pastingPictures(String event, Widget field) {
    if (event.isEmpty) return field;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) {
        final keys = HardwareKeyboard.instance;
        final paste = e is KeyDownEvent &&
            ((e.logicalKey == LogicalKeyboardKey.keyV &&
                    (keys.isControlPressed || keys.isMetaPressed)) ||
                (e.logicalKey == LogicalKeyboardKey.insert &&
                    keys.isShiftPressed));
        if (paste) {
          unawaited(host.clipboardHasPicture().then((has) {
            if (has && mounted) _send(event);
          }));
        }
        return KeyEventResult.ignored;
      },
      child: field,
    );
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
    for (final c in _scrollers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => KitSystemTheme(
        // frq's own palette in the dark, the kit's in the light, and on KDE
        // Plasma whatever System Settings says. Never on the web: there is no
        // kdeglobals to read and no `Platform` to ask.
        dark: t.frqDark,
        followKde: !kIsWeb,
        builder: (context, colors) => MaterialApp(
          title: 'frq',
          debugShowCheckedModeBanner: false,
          theme: KitTheme.material(colors),
          builder: (context, child) => KitTheme(
            colors: colors,
            child: DefaultTextStyle.merge(
              style: _style(t.textBody, colors.text),
              child: child!,
            ),
          ),
          // Everything inside one SelectionArea, so a message can be selected
          // and copied — and so can a nick, a timestamp, or a line of an
          // error. Per-widget `SelectableText` was the alternative and is
          // worse: it selects within one widget only, so a two-line answer
          // and the name above it cannot be dragged across, which is most of
          // what anyone wants to copy out of a chat.
          //
          // Taps still arrive: a selection starts on a drag, and the buttons,
          // faces and reaction pills under here keep their gestures.
          home: Material(
            color: colors.background,
            // The core decides what a window this size can hold — whether
            // the room list rides beside the conversation, whether there is
            // a back button — and it cannot measure one. A window is the
            // host's, like a socket or a clock, so the host says.
            //
            // From the constraints rather than MediaQuery: this is the space
            // the tree is actually given, which is what the decision is
            // about. Reported after the frame, because a dispatch is a
            // setState and a setState during build is an error.
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth.round();
                  final h = constraints.maxHeight.round();
                  if (w != _reportedW || h != _reportedH) {
                    _reportedW = w;
                    _reportedH = h;
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _send('window.size', '${w}x$h');
                    });
                  }
                  _c = colors;
                  return SelectionArea(child: _build(_tree));
                },
              ),
            ),
          ),
        ),
      );

  // ---------------------------------------------------------------- helpers

  TextStyle _style(double size, Color color) =>
      TextStyle(fontSize: size, color: color, height: 1.35);

  /// The style for a widget whose whole content is an emoji glyph.
  ///
  /// Naming the colour emoji font is not belt and braces: a glyph like ✏️ is
  /// U+270F plus U+FE0F, and the variation selector is a *request* for emoji
  /// presentation, not a guarantee. DejaVu Sans claims U+270F, so ordinary
  /// fallback stops there and draws the monochrome pencil the text era had —
  /// while 🙂, which no text font covers, falls all the way through to the
  /// emoji font and looks right. That is why only some of the chips were
  /// wrong.
  ///
  /// A family list rather than one name, because the font that has them
  /// differs by platform, and a name nothing matches costs nothing.
  TextStyle _emojiStyle(double size) => TextStyle(
        fontSize: size,
        fontFamily: host.emojiFonts.isEmpty ? null : host.emojiFonts.first,
        fontFamilyFallback: host.emojiFonts.isEmpty ? null : host.emojiFonts,
      );

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
    return host.localImage(src);
  }

  /// [child] as a control that sends [onClick], or [child] alone when there
  /// is nothing to send. Flat: the pointer turns into a hand and that is all
  /// the feedback there is, because the child already looks like what it is.
  Widget _wrapTap(String onClick, Widget child) {
    if (onClick.isEmpty) return child;
    return _tap(() => _send(onClick), child);
  }

  Widget _tap(VoidCallback onTap, Widget child) =>
      Pressable(onPressed: onTap, builder: (_, _) => child);

  /// A `KitButton` with less padding and smaller type, for a row of chips.
  /// The same colours for the same states as the kit's own secondary and
  /// primary buttons; only the size differs.
  Widget _compactButton(String text, bool on, VoidCallback press) => Pressable(
        onPressed: press,
        builder: (context, s) {
          final bg = on
              ? (s.pressed
                  ? _c.accentPressed
                  : (s.hovered ? _c.accentHover : _c.accent))
              : (s.pressed ? _c.pressed : (s.hovered ? _c.hover : _c.surface));
          final border = s.focused ? _c.focus : (on ? bg : _c.border);
          return Container(
            height: kitControlHeight,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(kitRadius),
              border: Border.all(color: border, width: s.focused ? 2 : 1),
            ),
            // A Row that hugs its label, as KitButton's does: a Container
            // with an alignment would fill the Wrap's whole width instead.
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(text,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: on ? _c.onAccent : _c.text)),
            ]),
          );
        },
      );

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
    // A node that names itself keeps its element across rebuilds.
    //
    // The tree is rebuilt wholesale from the core, so Flutter matches
    // children by position unless something says otherwise — and a position
    // is not an identity when a line can arrive above. Everything Flutter
    // holds per element is at stake: text controllers, scroll offsets, and
    // the selectables a live text selection is made of.
    final key = n.prop('key', '');
    var w = _buildNode(n, axis);

    // `_Filling` has to stay outermost: the `Stack` in `overlay` looks for it
    // by type, and a `KeyedSubtree` around it is a `KeyedSubtree` as far as
    // that check is concerned — which is how the first version of this ended
    // up laying a flex child out against an unbounded height.
    if (w is _Filling && key.isNotEmpty) {
      return _Filling(KeyedSubtree(key: ValueKey(key), child: w.child));
    }

    // The row a reply's arrow is aiming at. Two keys on one widget is not a
    // thing, so they nest: the ValueKey keeps the element across rebuilds,
    // and the GlobalKey is how this frame finds it afterwards.
    if (n.prop('scrollHere', false)) {
      w = KeyedSubtree(key: _jumpKey, child: w);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final ctx = _jumpKey.currentContext;
        if (ctx == null || !mounted) return;
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          // A little down from the top, so the message that was replied to
          // is read with what came after it rather than alone against the
          // ceiling.
          alignment: 0.2,
        );
        _send('jump.done');
      });
    }
    return key.isEmpty ? w : KeyedSubtree(key: ValueKey(key), child: w);
  }

  Widget _buildNode(core.UiNode n, String axis) {
    final spacing = _d(n.props['spacing'], 0);
    final flex = axis == _row || axis == _column;

    // What this node's own children are being built into.
    final childAxis = switch (n.tag) {
      'page' || 'vbox' || 'card' || 'task-card' || 'scroll' || 'dialog' => _column,
      // A stack's children are laid out by the stack, not by a flex: an
      // `Expanded` among them is illegal, so they must not think they are
      // in one.
      'overlay' => _noAxis,
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

      /// A node with others floating over it — the backlog, with the button
      /// that takes you back to the present sitting on top of it.
      ///
      /// The floating children are given no height of their own, which is
      /// the whole point: a control that belongs to the backlog should not
      /// take a row away from it, and on a short window that row is what
      /// makes the screen overflow.
      case 'overlay':
        {
          final base = kids.isNotEmpty ? kids.first : const SizedBox.shrink();
          final over = kids.skip(1).toList();
          return expanded(Stack(
            children: [
              Positioned.fill(child: base),
              for (final o in over)
                // Two kinds of floating child. One sits at the bottom on its
                // own ground — a control over the conversation. The other
                // covers it: a picture being looked at is not something to
                // read the backlog through.
                if (o is _Filling)
                  Positioned.fill(child: o.child)
                else
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: t.spaceS,
                  child: Align(
                    alignment: Alignment.bottomCenter,
                    // Opaque, because it floats over the conversation: a
                    // control with the backlog showing through it is a
                    // control nobody can read, and "↓ Jump to present" sat
                    // on top of whatever line happened to be under it.
                    child: Container(
                      clipBehavior: Clip.antiAlias,
                      decoration: BoxDecoration(
                        color: _c.background,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: o,
                    ),
                  ),
                ),
            ],
          ));
        }

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
          // A panel that covers something needs a ground of its own, or what
          // it covers reads through it.
          if (n.prop('background', false)) {
            col = ColoredBox(color: _c.background, child: col);
          }
          // Said by a child of an `overlay`: fill it rather than float at the
          // bottom of it. Carried as a wrapper because the Stack above is the
          // only thing that can act on it.
          if (n.prop('fill', false)) return _Filling(col);
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
        final task = n.prop('task', false);
        final tap = n.prop('onClick', '');
        final ground = task ? _c.hover : _c.surface;
        final body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _spaced(kids, spacing > 0 ? spacing : t.spaceXxs,
                vertical: true));
        // The panel itself: flatkit's surface and border, or the accent edge
        // a task wears.
        Widget panel(Color fill) => Container(
              width: double.infinity,
              padding: const EdgeInsets.all(t.spaceXs),
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(t.radiusS),
                border: task
                    ? Border(
                        left: BorderSide(color: _c.accent, width: 3),
                        top: BorderSide(color: _c.accent.withValues(alpha: 0.4)),
                        right:
                            BorderSide(color: _c.accent.withValues(alpha: 0.4)),
                        bottom:
                            BorderSide(color: _c.accent.withValues(alpha: 0.4)),
                      )
                    : Border.all(color: _c.border),
              ),
              child: body,
            );
        // A card that is itself the control. Where every line in a list goes
        // to the same place, a button on each one is a small target beside a
        // large inert thing -- and on a phone the button is what wraps onto
        // a row of its own. The whole card takes the press instead, and its
        // ground changes under the pointer the way a flatkit button's does.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: t.spaceXxxs),
          child: tap.isEmpty
              ? panel(ground)
              : Pressable(
                  onPressed: () => _send(tap),
                  builder: (_, s) => panel(s.pressed
                      ? _c.pressed
                      : (s.hovered ? _c.hover : ground)),
                ),
        );

      // A typed handoff event's visible companion. A tinted box and coloured
      // edge distinguish the event, with a separate header for its status.
      case 'task-card':
        {
          final tone = n.prop('tone', 'neutral');
          final edge = switch (tone) {
            'new' => _c.accent,
            'active' => _c.text,
            'success' => _c.success,
            'danger' => _c.danger,
            _ => _c.textDim,
          };
          final headlineColor = switch (tone) {
            'new' => _c.accent,
            'success' => _c.success,
            'danger' => _c.danger,
            _ => _c.text,
          };
          return Container(
            width: double.infinity,
            margin: const EdgeInsets.symmetric(vertical: t.spaceXxxs),
            decoration: BoxDecoration(
              color: n.prop('highlight', false)
                  ? _c.hover
                  : Color.alphaBlend(edge.withValues(alpha: 0.06), _c.surface),
              borderRadius: BorderRadius.circular(t.radiusS),
              border: Border(
                left: BorderSide(color: edge, width: 3),
                top: BorderSide(color: edge.withValues(alpha: 0.55)),
                right: BorderSide(color: edge.withValues(alpha: 0.55)),
                bottom: BorderSide(color: edge.withValues(alpha: 0.55)),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: edge.withValues(alpha: 0.08),
                    border: Border(
                      bottom: BorderSide(color: edge.withValues(alpha: 0.25)),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                      horizontal: t.spaceXs, vertical: t.spaceXxs),
                  child: Row(children: [
                    Text(n.prop('glyph', ''), style: _emojiStyle(t.textCaption)),
                    const SizedBox(width: t.spaceXxs),
                    Text(n.prop('headline', '').toUpperCase(),
                        style: _style(t.textCaption, headlineColor)
                            .copyWith(fontWeight: FontWeight.w700)),
                    if (n.prop('eventId', '').isNotEmpty) ...[
                      const SizedBox(width: t.spaceXxs),
                      Flexible(
                        child: Text(n.prop('eventId', ''),
                            overflow: TextOverflow.ellipsis,
                            style: _style(10, _c.textDim)),
                      ),
                    ],
                    const Spacer(),
                    if (n.prop('replyOnClick', '').isNotEmpty)
                      _wrapTap(
                        n.prop('replyOnClick', ''),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 3),
                          decoration: BoxDecoration(
                            color: _c.hover,
                            borderRadius: BorderRadius.circular(t.radiusS),
                          ),
                          child: Text('💬', style: _emojiStyle(14)),
                        ),
                      ),
                    if (n.prop('replyOnClick', '').isNotEmpty)
                      const SizedBox(width: t.spaceXxs),
                    Text(n.prop('time', ''), style: _style(10, _c.textDim)),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.all(t.spaceXs),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: _spaced(kids, t.spaceXxs, vertical: true),
                  ),
                ),
              ],
            ),
          );
        }

      case 'title':
        final shrinks = n.prop('shrink', false);
        final heading = Text(n.prop('label', ''),
            maxLines: shrinks ? 1 : null,
            overflow: shrinks ? TextOverflow.ellipsis : TextOverflow.clip,
            style: _style(t.textTitle3, _c.text)
                .copyWith(fontWeight: FontWeight.bold));
        // `Flexible` and deliberately not `Expanded`: a room's name should
        // take the width it needs and no more, so the controls stay gathered
        // beside it instead of being flung to the far edge. What it gives up
        // is only the width it does not have -- a name longer than the row
        // ellipsises, where before it pushed a control onto a second line.
        return shrinks && flex ? Flexible(child: heading) : heading;

      case 'title-2':
        return Padding(
          padding: const EdgeInsets.only(top: t.spaceXxs, bottom: t.spaceXxxs),
          child: Text(n.prop('label', ''),
              style: _style(t.textTitle4, _c.text)
                  .copyWith(fontWeight: FontWeight.w600)),
        );

      case 'label':
        return Text(n.prop('label', ''), style: _style(t.textBody, _c.text));

      // Output — a diff, a log — as a block: monospace, on the card's own
      // tint, and scrolling past `maxHeight` rather than pushing the row
      // further down a channel of them.
      case 'code-block':
        {
          final maxHeight = _d(n.props['maxHeight'], 160);
          return Container(
            width: double.infinity,
            constraints: BoxConstraints(maxHeight: maxHeight),
            padding: const EdgeInsets.symmetric(
                horizontal: t.spaceXxs, vertical: t.spaceXxxs),
            child: SingleChildScrollView(
              child: SelectableText(n.prop('text', ''),
                  style: _style(t.textCaption, _c.accent)
                      .copyWith(fontFamily: 'monospace', height: 1.35)),
            ),
          );
        }

      case 'dim-label':
        return Text(n.prop('label', ''), style: _style(t.textCaption, _c.textDim));

      /// Prose, as opposed to a label: this is what a message is, and it
      /// wraps. Kept apart from `label` because a wrapping label in a row
      /// lays out against the row's width rather than the column's.
      case 'text':
        // `lines` clamps to that many and ellipsises. A character count
        // cannot do this job: how much fits on a line is a fact about the
        // font and the width, and the two disagree — in a widget test the
        // same 96 characters take five lines where a phone gives them two.
        final lines = n.prop('lines', 0);
        return Text(n.prop('text', ''),
            maxLines: lines > 0 ? lines : null,
            overflow: lines > 0 ? TextOverflow.ellipsis : TextOverflow.clip,
            style: _style(t.textBody, _c.text));

      case 'link':
        {
          // The same rule the inline links follow: a link with no `onClick`
          // opens its own `url`. `Open on bsky.app` in the profile panel is
          // this one, and it was underlined, blue and inert for exactly the
          // reason the ones in a message were — `_wrapTap` hands back a bare
          // child when there is no event to send, and a link's event was
          // never the point. Opening a URL is the platform's job.
          final url = n.prop('url', '');
          final onClick = n.prop('onClick', '');
          final label = Text(
            n.prop('label', ''),
            style: _style(t.textBody, _c.accent)
                .copyWith(decoration: TextDecoration.underline,
                          decorationColor: _c.accent),
          );
          if (onClick.isNotEmpty) return _wrapTap(onClick, label);
          if (url.isEmpty) return label;
          return _tap(() => host.openUrl(url), label);
        }

      case 'separator':
        return const KitDivider();

      case 'spacer':
        {
          final s = _d(n.props['size'], t.spaceXxs);
          return SizedBox(width: s, height: s);
        }

      case 'spinner':
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const KitSpinner(),
            if (n.prop('label', '').isNotEmpty) ...[
              const SizedBox(width: t.spaceXxs),
              Text(n.prop('label', ''), style: _style(t.textCaption, _c.textDim)),
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
                color: n.prop('live', false) ? _c.success : _c.textDim,
                borderRadius: BorderRadius.circular(t.radiusXs),
              ),
            ),
            const SizedBox(width: 6),
            Text(n.prop('label', ''), style: _style(t.textCaption, _c.textDim)),
          ],
        );

      case 'button':
        {
          final onClick = n.prop('onClick', '');
          final kind = n.prop('kind', 'default');
          final text = n.prop('label', '');
          void press() => _send(onClick);
          // A sender's name: a way in to who someone is, but it sits in the
          // middle of a line and must not look like a control. Text that
          // takes a press, with no chrome at all.
          if (kind == 'plain') {
            final plain = _tap(
              press,
              Text(text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: _style(t.textBody, _c.text)),
            );
            // `Expanded`, and the name is drawn at the left of the box it
            // gets. That box is the slack: it grows to fill the row, so
            // whatever follows the name is carried to the far edge, and it
            // shrinks when the row is too narrow for everything, so a long
            // handle ellipsises rather than pushing the time and the chips
            // off the end.
            //
            // `Flexible` was tried first and is the trap: its flex is 1, so
            // it competed with the `Spacer` beside it for the free space,
            // took half, used the 70 points the name needed and left the
            // rest as a hole at the end of the row. The chips looked
            // right-aligned to nothing in particular, 365 points short of
            // the edge.
            return (n.prop('expand', false) && flex)
                ? Expanded(
                    child: Align(alignment: Alignment.centerLeft, child: plain))
                : plain;
          }
          // A control in a row that has more of them than a phone is wide.
          // Three chips beside a room's name come to more than 360 points
          // at KitButton's 12 either side and 14-point label, so the padding
          // and the type, not the wording, are what there is no room for.
          // This keeps every label and spends the space on them instead.
          if (kind == 'compact' || kind == 'compact-on') {
            return _compactButton(text, kind == 'compact-on', press);
          }
          return switch (kind) {
            'primary' => KitButton.primary(text, onPressed: press),
            'destructive' => KitButton.danger(text, onPressed: press),
            _ => KitButton(text, onPressed: press),
          };
        }

      case 'checkbutton':
        // The label is part of the target, and Flexible inside the kit's
        // row: "Hide join/part messages" beside a checkbox overflows a phone
        // otherwise. A little air above and below, so the row is a target a
        // thumb can find.
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: t.spaceXxxs),
          child: KitCheckbox(
            value: n.prop('active', false),
            label: n.prop('label', ''),
            onChanged: (_) => _send(n.prop('onToggled', '')),
          ),
        );

      case 'emoji':
        return _wrapTap(
          n.prop('onClick', ''),
          Text(n.prop('glyph', n.prop('emoji', '')),
              style: _emojiStyle(_d(n.props['size'], 16))),
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
                color: mine ? _c.accent : _c.hover,
                borderRadius: BorderRadius.circular(t.radiusS),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(n.prop('emoji', ''), style: _emojiStyle(size)),
                  if (count > 0) ...[
                    const SizedBox(width: 4),
                    Text('$count',
                        style: _style(t.textCaption,
                            mine ? _c.onAccent : _c.textDim)),
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
          final url = n.prop('url', '');
          final fallback = n.prop('fallback', '');
          final initial = Text(
              fallback.isNotEmpty ? fallback.substring(0, 1).toUpperCase() : '?',
              style: _style(t.textBody, _c.text));
          // Through the host rather than as a `backgroundImage`: on the web a
          // face is an <img> the browser fetches, which is the only kind CORS
          // lets through, and an element cannot be a decoration.
          final face = Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(color: _c.hover, shape: BoxShape.circle),
            child: url.isEmpty
                ? initial
                : SizedBox(
                    width: size,
                    height: size,
                    child: host.networkImage(url,
                        fit: BoxFit.cover, onError: () => initial),
                  ),
          );
          return _wrapTap(n.prop('onClick', ''), face);
        }

      case 'image':
        {
          final src = n.prop('src', '');
          if (src.isEmpty) return const SizedBox.shrink();
          final maxW = _d(n.props['maxWidth'], 0);
          final maxH = _d(n.props['maxHeight'], 0);
          // A half-written cache file, or one deleted under us: the decoder
          // throws during the build, and an exception in a build is a red
          // screen for the whole conversation rather than a gap where one
          // picture was.
          Widget img;
          if (src.startsWith('http://') || src.startsWith('https://')) {
            img = host.networkImage(src);
          } else {
            final provider = _imageProvider(src);
            if (provider == null) return const SizedBox.shrink();
            img = Image(
              image: provider,
              fit: BoxFit.contain,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            );
          }
          if (maxW > 0 || maxH > 0) {
            img = ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: maxW > 0 ? maxW : double.infinity,
                maxHeight: maxH > 0 ? maxH : double.infinity,
              ),
              child: img,
            );
          }
          // `expand` on a picture is what makes a lightbox a lightbox: in
          // the column of a panel that fills the screen, it takes the height
          // that is left and `BoxFit.contain` does the rest.
          return expanded(_wrapTap(n.prop('onClick', ''), img));
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
          // A field holding an identifier, not a sentence.
          //
          // A phone keyboard is built for prose and every one of its helps
          // is wrong here: it capitalises the first letter of a handle,
          // suggests a word it guessed at, and -- the one that prompted
          // this -- inserts a space after a full stop, because a full stop
          // ends a sentence. It is also the middle of `alice.bsky.social`,
          // and a handle with a space in it resolves to nothing.
          //
          // `TextInputType.url` is the layout that suits it: a full stop on
          // the main plane and no space bar to be helpful with.
          final verbatim = n.prop('verbatim', false);
          final focus = _focus.putIfAbsent(key, FocusNode.new);
          final input = TextField(
            controller: c,
            focusNode: focus,
            style: _style(t.textBody, _c.text),
            cursorColor: _c.accent,
            cursorWidth: 1.5,
            autocorrect: !verbatim,
            enableSuggestions: !verbatim,
            textCapitalization: verbatim
                ? TextCapitalization.none
                : TextCapitalization.sentences,
            keyboardType: verbatim ? TextInputType.url : null,
            decoration: InputDecoration(
              isCollapsed: true,
              border: InputBorder.none,
              hintText: n.prop('placeholder', ''),
              hintStyle: _style(t.textBody, _c.textDim),
              hintFadeDuration: Duration.zero,
            ),
            onChanged: (v) => _send(n.prop('onChange', ''), v),
            onSubmitted: (_) => _send(n.prop('onSubmit', '')),
          );
          // `KitTextField`'s frame, drawn here rather than used: the kit's
          // field owns its own focus node and keyboard settings, and this one
          // needs the node held per key (see `_focus`) and the `verbatim`
          // settings above. The look is the kit's — a flat border that turns
          // the focus colour, no underline, no fill animation.
          final field = GestureDetector(
            onTap: focus.requestFocus,
            child: MouseRegion(
              cursor: SystemMouseCursors.text,
              child: ListenableBuilder(
                listenable: focus,
                builder: (_, child) => Container(
                  height: kitControlHeight + 2,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: _c.surface,
                    borderRadius: BorderRadius.circular(kitRadius),
                    border: Border.all(
                        color: focus.hasFocus ? _c.focus : _c.border,
                        width: focus.hasFocus ? 2 : 1),
                  ),
                  child: child,
                ),
                child: input,
              ),
            ),
          );
          final w = _d(n.props['widthRequest'], 0);
          final pasted = _pastingPictures(n.prop('onPastePicture', ''), field);
          if (w > 0) return SizedBox(width: w, child: pasted);
          // No width asked for: take the rest of the row where there is a row
          // to take it from, and otherwise a definite width. NOT Expanded
          // unconditionally — a TextField has no intrinsic width, so in a Wrap
          // it is both illegal and unmeasurable, and that combination is what
          // took the whole screen down rather than one field.
          return axis == _row
              ? Expanded(child: pasted)
              : SizedBox(width: _unsizedEntry, child: pasted);
        }

      case 'scroll':
        {
          // Both ends of the same scroll, named so they are the same one.
          final scrollKey = n.prop('scrollKey', 'scroll');
          final c = _scrollers.putIfAbsent(scrollKey, ScrollController.new);
          final stick = n.prop('stickToBottom', false);
          // Opens at its end, which is a different thing from being the
          // backlog. `stickToBottom` carries two meanings -- read from the
          // bottom, and report whether the reader is at the present -- and
          // only the backlog has a present to be at. The overview wants the
          // first of those and not the second.
          final fromBottom = n.prop('fromBottom', false);

          // "Jump to present": a tick that goes up, rather than a flag that
          // would have to be cleared. A reverse scroll holds the present at
          // offset zero, which is why this is not maxScrollExtent.
          final tick = n.prop('scrollToBottom', 0);
          if (_bottomTicks[scrollKey] != tick) {
            _bottomTicks[scrollKey] = tick;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!c.hasClients) return;
              c.animateTo(
                stick ? c.position.minScrollExtent
                      : c.position.maxScrollExtent,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOut,
              );
            });
          }
          // How far from the present counts as having left it. Enough that
          // the last line being taller than the gap does not toggle this on
          // its own, and little enough that a nudge upward and back does not
          // leave the button on screen.
          const away = 120.0;
          Widget body = SingleChildScrollView(
            controller: c,
            // The backlog reads from the bottom; a settings list from the top.
            reverse: stick || fromBottom,
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _spaced(kids, spacing, vertical: true)),
          );
          body = Scrollbar(controller: c, child: body);

          // Only the backlog reports this. A settings list has no present to
          // be at, and telling the core about one would put the chat
          // screen's button on the wrong screen's scrolling.
          if (stick) {
            body = NotificationListener<ScrollNotification>(
              onNotification: (note) {
                if (note.depth != 0) return false;
                final m = note.metrics;
                // Reversed, so the present is the zero end.
                final here = m.pixels <= m.minScrollExtent + away;
                if (_atPresent[scrollKey] != here) {
                  _atPresent[scrollKey] = here;
                  _send(here ? 'present.back' : 'present.left');
                }
                return false;
              },
              child: body,
            );
          }
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
        // KitDialog's look, but laid out where the tree puts it: the core
        // decides where a dialog goes, so this is a panel, not a route.
        return Container(
          margin: const EdgeInsets.all(t.spaceXxxs),
          padding: const EdgeInsets.all(t.spaceS + t.spaceXxxs),
          decoration: BoxDecoration(
            color: _c.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _c.border),
            boxShadow: [
              BoxShadow(
                  color: _c.shadow, blurRadius: 24, offset: const Offset(0, 8)),
            ],
          ),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (n.prop('title', '').isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: t.spaceXxs),
                    child: Text(n.prop('title', ''),
                        style: _style(t.textTitle4, _c.text)
                            .copyWith(fontWeight: FontWeight.w600)),
                  ),
                ..._spaced(kids, spacing, vertical: true),
              ],
            ),
        );

      default:
        // An unknown tag paints as itself rather than crashing or vanishing.
        // Nim can add one and see it before this file has heard of it, which
        // is what makes the boundary pleasant to work across.
        return Container(
          padding: const EdgeInsets.all(4),
          color: _c.danger.withValues(alpha: 0.3),
          child: Text('?${n.tag}'),
        );
    }
  }

  /// One node of an inline paragraph, as a span.
  ///
  /// The core splits task output into text, links and a small set of inline
  /// Markdown styles. Anything else falls back to plain text so an unexpected
  /// tag degrades to something readable rather than vanishing.
  InlineSpan _span(core.UiNode n) {
    switch (n.tag) {
      case 'link':
        final url = n.prop('url', n.prop('label', ''));
        final onClick = n.prop('onClick', '');
        return TextSpan(
          text: n.prop('label', ''),
          style: _style(t.textBody, _c.accent)
              .copyWith(decoration: TextDecoration.underline,
                        decorationColor: _c.accent),
          // A link with no `onClick` opens itself, which is every link in a
          // message: `textruns` emits a label and a URL and nothing else, so
          // until now they were underlined, blue, and inert. Opening one is
          // the platform's job rather than the core's — a browser tab here,
          // `xdg-open` there — so it goes through the host rather than back
          // across the seam as an event the core could not act on.
          recognizer: _linkTaps[url] ??= TapGestureRecognizer()
            ..onTap = () {
              if (onClick.isNotEmpty) {
                _send(onClick);
              } else if (url.isNotEmpty) {
                host.openUrl(url);
              }
            },
        );
      case 'text':
        return TextSpan(
            text: n.prop('text', ''), style: _style(t.textBody, _c.text));
      case 'strong':
        return TextSpan(
            text: n.prop('text', ''),
            style: _style(t.textBody, _c.text)
                .copyWith(fontWeight: FontWeight.w700));
      case 'emphasis':
        return TextSpan(
            text: n.prop('text', ''),
            style: _style(t.textBody, _c.text)
                .copyWith(fontStyle: FontStyle.italic));
      case 'code':
        return TextSpan(
            text: n.prop('text', ''),
            style: _style(t.textBody, _c.text).copyWith(
              fontFamily: 'monospace',
              color: _c.accent,
            ));
      default:
        return TextSpan(
            text: n.prop('label', n.prop('text', '')),
            style: _style(t.textBody, _c.text));
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
