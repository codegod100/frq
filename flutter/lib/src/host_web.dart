/// The same two things, in a browser, where there is neither.
///
/// A page has no environment: `FRQ_AUTOCONNECT` is a thing you set before
/// starting a process, and nothing here was started that way. And it has no
/// filesystem the renderer could open — a picture a reader attaches arrives
/// as a blob URL or not at all, and the path branch is never reached.
library;

import 'dart:js_interop';

import 'package:flutter/widgets.dart';

String envOr(String name, String fallback) => fallback;

ImageProvider? localImage(String path) => null;

/// A picture from the network, drawn by the browser rather than decoded by
/// Flutter.
///
/// This is the one place the web build cannot simply use the same widget.
/// Flutter fetches image bytes with an XMLHttpRequest so it can decode them
/// into a texture, and an XHR is subject to CORS — so every avatar on
/// `cdn.bsky.app` and every picture on freeq's media host failed with "No
/// 'Access-Control-Allow-Origin' header", because neither sends one to a
/// third-party page and neither has any reason to.
///
/// An `<img>` element has never needed permission to display a picture, and
/// `WebHtmlElementStrategy.prefer` is Flutter asking for exactly that: the
/// browser loads and draws it, and Flutter positions the element. The cost is
/// that such an image is outside the canvas — it cannot be blended or
/// transformed like a texture — which for a face and a photograph in a
/// conversation is no cost at all.
Widget networkImage(String url,
        {BoxFit fit = BoxFit.contain,
        Widget Function()? onError}) =>
    Image.network(url,
        fit: fit,
        webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
        errorBuilder: (_, _, _) =>
            onError == null ? const SizedBox.shrink() : onError());

/// No family is named on the web, and that is the fix rather than the gap.
///
/// A browser is not painting with the machine's fonts: CanvasKit carries its
/// own and fetches a Noto face on demand for glyphs it cannot draw. Naming a
/// family it does not have defeats that — a named family that is missing is
/// a notdef box rather than a search, and every chip drew ▯.
///
/// That was tried twice. The second time was on the theory that the first
/// result had come through a stale service worker; it had not, and the boxes
/// came straight back. What a glyph gets here is whatever CanvasKit's own
/// fallback finds, which for an emoji-presentation codepoint is the colour
/// face — and for a text codepoint wearing a variation selector is not. See
/// `screens/chat`, where the chips are chosen accordingly.
const List<String> emojiFonts = <String>[];

@JS('window.open')
external void _windowOpen(JSString url, JSString target);

/// Open a URL in another tab.
///
/// `_blank`, and not this one: a reader following a link out of a
/// conversation has not asked to leave the conversation, and a page that
/// navigated away would lose the socket and everything in it.
void openUrl(String url) {
  _windowOpen(url.toJS, '_blank'.toJS);
}
