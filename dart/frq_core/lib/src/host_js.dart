/// The web half of the seam: the same core, compiled by `nim js`.
///
/// `nim/web/frq_web.nim` puts one object on `globalThis` and these are its
/// methods. No pointers and nothing to free — a string is a string — so this
/// file is short where `host_ffi.dart` is careful.
///
/// The functions that are not here in spirit are the ones a browser has no
/// business calling: the socket is JavaScript's on this target, opened by the
/// page rather than by Dart, so `connOpenAt` and its neighbours throw rather
/// than pretend. They are reached only by the native tests and by
/// `tool/live_ui.dart`.
library;

import 'dart:js_interop';

@JS('frq')
external _Frq get _frq;

@JS()
@staticInterop
class _Frq {}

extension on _Frq {
  external JSString render();
  external JSString dispatch(JSString event);
  external void demo();
  external void trace(JSBoolean on);
}

String? uiRender() => _frq.render().toDart;

/// The same call as [uiRender]. There is no cheaper "has anything changed?"
/// on this side either — the core drains its queue and builds a tree, and the
/// comparison that saves the work happens a layer up, on the JSON.
String? uiPoll() => _frq.render().toDart;

String? uiDispatch(String event) => _frq.dispatch(event.toJS).toDart;

void uiDemo() => _frq.demo();

void uiReset() => _frq.dispatch('{"id":"reset"}'.toJS);

String hostVersion() => 'js';

Never _notHere(String what) => throw UnsupportedError(
    '$what is not available in the browser build: the page owns the socket '
    'and the core is reached through globalThis.frq');

String? str1(String symbol, String arg) => _notHere(symbol);
String? tagValueOf(String tags, String key) => _notHere('tag values');
void traceTo(String topic, String msg) => _frq.trace(true.toJS);
void connOpenAt(String host, int port, bool tls) => _notHere('connOpen');
void connSendLine(String line) => _notHere('connSend');
void connCloseNow() => _notHere('connClose');
String? connRecvLine() => _notHere('connRecv');
String? connEventNext() => _notHere('connEvent');
