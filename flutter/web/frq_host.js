// The half of the web build that owns the I/O.
//
// `frq_core.js` is the same Nim the desktop runs, compiled by `nim js`. It
// holds the state and builds the screens, and it opens nothing: a browser
// cannot dial a TCP socket, and `frq/conn` on this target is a pair of queues
// rather than two threads. This file is what fills them.
//
// Three jobs, and nothing else:
//
//   * the socket. The core says where it wants to be connected; this opens a
//     WebSocket to freeq's own bridge, feeds every line in, and sends
//     everything the core has queued.
//   * the sign-in. The broker answers by redirecting the page back with a
//     payload in the fragment, so a sign-in finishes on the *next* load —
//     this reads it, hands it over, and takes it off the URL.
//   * the profiles, which the core asks for through `fetch` (in the Nim, not
//     here), so there is nothing to do for them.
//
// Flutter draws. It reaches the core through `dart:js_interop`, and never
// touches any of this.

(function () {
  "use strict";

  var ws = null;
  var wantedNow = "";

  // freeq publishes this for exactly this case — the same server, the same
  // SASL, over a transport a page is allowed to open. The host and the
  // scheme come from what the core asked for; the path is the bridge's.
  function urlFor(cfg) {
    return "wss://" + cfg.host + "/irc";
  }

  function connect(cfg) {
    var url = urlFor(cfg);
    try {
      ws = new WebSocket(url);
    } catch (e) {
      frq.socketEvent("error: " + e);
      return;
    }
    ws.onopen = function () { frq.socketEvent("open"); };
    ws.onmessage = function (ev) {
      // A frame can carry more than one line, and carries the CRLF the wire
      // format puts between them. The core wants lines.
      String(ev.data).split(/\r?\n/).forEach(function (line) {
        if (line.length > 0) frq.feed(line);
      });
    };
    ws.onclose = function (ev) {
      ws = null;
      wantedNow = "";
      frq.socketEvent("close: " + (ev.reason || "the connection ended"));
    };
    ws.onerror = function () {
      // `onerror` carries nothing worth reporting — the browser withholds the
      // reason on purpose — and `onclose` always follows, so the message the
      // reader sees comes from there.
      frq.socketEvent("error: the connection failed");
    };
  }

  // The pump. Both directions, on a timer, because nothing here is allowed to
  // call into Dart and Dart is not going to ask on the core's behalf.
  //
  // Twenty times a second: fast enough that a keystroke's PRIVMSG does not
  // sit in a queue where a reader would notice, and slow enough to be free.
  setInterval(function () {
    var want = frq.wanted();
    if (want && want !== wantedNow) {
      wantedNow = want;
      if (ws) { try { ws.close(); } catch (e) {} ws = null; }
      connect(JSON.parse(want));
    }
    if (ws && ws.readyState === 1) {
      var out = frq.takeOutbound();
      if (out) {
        out.split("\n").forEach(function (line) {
          if (line.length > 0) ws.send(line);
        });
      }
    }
  }, 50);

  // The broker's answer, which arrives as a fragment on a fresh load.
  //
  // Taken off the URL once read: a payload carries a single-use token, and
  // leaving it in the address bar means it is in the history, in whatever
  // the reader pastes, and replayed by a refresh.
  var payload = "";
  if (window.location.hash) {
    var h = window.location.hash.replace(/^#/, "");
    payload = new URLSearchParams(h).get("oauth") || h.replace(/^oauth=/, "");
    history.replaceState(null, "", window.location.pathname + window.location.search);
  }

  frq.init(payload);
})();
