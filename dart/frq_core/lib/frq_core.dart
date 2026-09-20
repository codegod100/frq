/// The Nim core, as Dart functions.
///
/// The logic lives in Nim; this is the shape it takes on this side. Two hosts
/// answer it — `src/host_ffi.dart` through `dart:ffi` on a desktop, and
/// `src/host_js.dart` against the `nim js` build in a browser — and
/// `src/host.dart` is the one line that chooses. Nothing below this comment
/// knows which, which is the point: the widget tree, its decoding, and the
/// change detection that makes polling cheap are the same work whatever
/// produced the JSON.
///
/// **Dart and not ClojureDart, on purpose.** The point of the Nim core is to
/// have less Clojure, so new code on this side of the boundary is written in
/// the language the platform speaks.
///
/// No `package:ffi` either. That package exists mostly for `Utf8`
/// conversions, and doing them against `dart:convert` costs about ten lines
/// and keeps `pubspec.yaml` unchanged.
library;

import 'dart:convert';

import 'src/host.dart' as host;

// ------------------------------------------------------------------ public

/// The core's version, for a caller that wants to check the library it found
/// is the one it was built against.
String get version => host.hostVersion();

/// An IRC line, taken apart: `{raw, tags, account, prefix, command, params}`.
///
/// `tags`, `account` and `prefix` are null where the line carried none, which
/// is the distinction `frq.irc.parse` draws with nil and every caller depends
/// on — a PRIVMSG from a server with no prefix is not the same line as one
/// from a nick.
Map<String, dynamic> parseLine(String line) {
  final json = host.str1('frq_irc_parse_line', line);
  return jsonDecode(json ?? 'null') as Map<String, dynamic>;
}

/// One IRCv3 tag's value, unescaped — null where the tag is absent OR empty,
/// which IRCv3 says are the same thing.
String? tagValue(String tags, String key) {
  return host.tagValueOf(tags, key);
}

String unescapeTag(String v) => host.str1('frq_irc_unescape_tag', v) ?? '';

String escapeTagValue(String v) => host.str1('frq_irc_escape_tag_value', v) ?? '';

/// The nick half of a `nick!user@host` prefix.
String nickOf(String prefix) => host.str1('frq_irc_nick_of', prefix) ?? '';


/// Log through the Nim core's trace facility, so `FRQ_TRACE=1` gives one
/// interleaved story rather than two half-ones in different places.
void trace(String topic, String msg) {
  host.traceTo(topic, msg);
}

// --------------------------------------------------------------- transport
//
// `frq.net`'s three operations, with a Nim socket behind them. This is the
// wiring that leaves the existing ClojureDart screens, cells and actions
// alone: only the transport underneath them is Nim.


/// Dial. Non-blocking: the socket runs on a Nim thread and progress arrives
/// through [connEvent].
void connOpen(String hostname, int port, {bool tls = true}) =>
    host.connOpenAt(hostname, port, tls);


/// Queue a line. The transport adds the CRLF.
void connSend(String line) => host.connSendLine(line);


void connClose() => host.connCloseNow();

/// The next line, or null when none is waiting. Never blocks.
String? connRecv() => host.connRecvLine();

/// The next transport event — `open`, `close: …`, `error: …` — or null.
String? connEvent() => host.connEventNext();


// ---------------------------------------------------------------- the UI
//
// Nim owns the state and the screens; Dart owns the pixels. A tree goes out,
// an event id comes back, and nothing else crosses.
//
// `UiNode` is deliberately a dumb bag — a tag, a props map, children. A class
// per widget would put the tag vocabulary in two places and make every new tag
// a change on both sides; the point is that Nim can grow a screen without this
// file being touched.

/// One node of the widget tree Nim emitted.
class UiNode {
  final String tag;
  final Map<String, dynamic> props;
  final List<UiNode> children;

  const UiNode(this.tag, this.props, this.children);

  factory UiNode.fromJson(Map<String, dynamic> j) => UiNode(
        j['tag'] as String,
        (j['props'] as Map?)?.cast<String, dynamic>() ?? const {},
        ((j['children'] as List?) ?? const [])
            .map((c) => UiNode.fromJson((c as Map).cast<String, dynamic>()))
            .toList(growable: false),
      );

  /// A prop, or [fallback] when it is absent or the wrong shape. Tolerant on
  /// purpose: a renderer should skip a prop it does not understand rather than
  /// fail a whole screen over one.
  T prop<T>(String name, T fallback) {
    final v = props[name];
    return v is T ? v : fallback;
  }

  /// Structural, and that matters: the poll loop compares two trees by this
  /// string to decide whether to rebuild. A summary showing only tags and prop
  /// NAMES would call two screens equal when a message had arrived, and the
  /// room would never appear to fill.
  @override
  String toString() =>
      '<$tag $props ${children.map((c) => c.toString()).join()}>';
}

UiNode _treeFrom(String? json) =>
    UiNode.fromJson(jsonDecode(json ?? _emptyTree) as Map<String, dynamic>);

/// A tree and the JSON it came from.
///
/// The raw string is kept because it is the cheapest possible change
/// detector: Nim already produced it, and comparing two strings is free
/// beside decoding one. The renderer polls ten times a second and the answer
/// is almost always "nothing changed" — doing a `jsonDecode` and two
/// recursive `toString()`s to discover that was most of the idle cost of the
/// app in a busy room.
const _emptyTree = '{"tag":"vbox"}';

class UiFrame {
  final String json;
  final UiNode tree;
  const UiFrame(this.json, this.tree);
}

/// The current screen.
///
/// Not pure: the Nim side drains the socket's queue first, so two calls with
/// no [dispatch] between can differ when a line arrived in the gap. That is how
/// the room fills, and why the renderer polls.
UiNode render() => _treeFrom(
    host.uiRender());

/// The tree, asked for because time passed rather than because anything
/// happened. Same work as [render]; named for what the caller means.
UiNode poll() => _treeFrom(
    host.uiPoll());

/// The current screen, with the JSON it came from. The starting point for
/// [pollIfChanged].
UiFrame renderFrame() {
  final json = host.uiRender() ?? _emptyTree;
  return UiFrame(json, _treeFrom(json));
}

/// The tree, decoded only when it differs from [since] — otherwise null,
/// meaning "the screen you already have is current".
///
/// This is what the renderer polls with. The comparison is the JSON Nim
/// already produced, so an unchanged frame costs one string compare rather
/// than a decode and two recursive `toString()`s.
UiFrame? pollIfChanged(String since) {
  final json = host.uiPoll() ?? _emptyTree;
  if (json == since) return null;
  return UiFrame(json, _treeFrom(json));
}

/// Apply an event and get the tree it produced.
///
/// One call rather than dispatch-then-render, and not to save a crossing: it
/// makes the pair atomic, so there is no window in which Dart could render a
/// state nothing asked for.
UiNode dispatch(String id, [String value = '']) => dispatchFrame(id, value).tree;

/// As [dispatch], but keeping the JSON so the poll loop can compare against
/// it without re-stringifying the tree it just built.
UiFrame dispatchFrame(String id, [String value = '']) {
  final json = host.uiDispatch(jsonEncode({'id': id, 'value': value})) ??
      _emptyTree;
  return UiFrame(json, _treeFrom(json));
}


/// What an upload needs — `{host, did, channel}` as JSON — or empty where
/// nothing is wanted. Taken as it is read: a file dialog opened twice is one
/// the reader has to dismiss twice.
String wantedPicture() => host.wantedPicture() ?? '';

/// Fill a room with a representative conversation, so a test can lay the chat
/// screen out without a server. See the Nim side for why it exists.
void demoUi() => host.uiDemo();

/// Back to a fresh state, for a caller that wants a known starting point.
void resetUi() => host.uiReset();
