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
//   * the sign-in, which `frq_oauth.js` does and this drives. The core asks
//     for a sign-in, for a proof, or to be forgotten; each answer goes back
//     through a function on the core. A sign-in finishes on the *next* load,
//     because the authorization leg leaves the page.
//   * the profiles, which the core asks for through `fetch` (in the Nim, not
//     here), so there is nothing to do for them.
//   * a picture: the file dialog and the upload, because both are the
//     platform's rather than the core's.
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
    var sock;
    try {
      sock = new WebSocket(url);
    } catch (e) {
      frq.socketEvent("error: " + e);
      return;
    }
    ws = sock;
    var opened = false;
    sock.onopen = function () {
      if (ws !== sock) return;
      opened = true;
      frq.socketEvent("open");
    };
    sock.onmessage = function (ev) {
      if (ws !== sock) return;
      // A frame can carry more than one line, and carries the CRLF the wire
      // format puts between them. The core wants lines.
      String(ev.data).split(/\r?\n/).forEach(function (line) {
        if (line.length > 0) frq.feed(line);
      });
    };
    // One event per socket, from `onclose`. `onerror` carries nothing worth
    // reporting — the browser withholds the reason on purpose — and `onclose`
    // always follows it; saying both told the core the connection ended
    // twice, and the second arrived after the core had already dialled again.
    //
    // And only for the socket that is current: one closed because the core
    // asked for another still fires `onclose`, late, and was taken for the
    // new one ending.
    sock.onclose = function (ev) {
      if (ws !== sock) return;
      ws = null;
      wantedNow = "";
      frq.socketEvent(opened
        ? "close: " + (ev.reason || "the connection ended")
        : "error: the connection failed");
    };
  }

  function hangUp() {
    if (!ws) return;
    var old = ws;
    ws = null;
    try { old.close(); } catch (e) {}
  }

  // The pump. Both directions, on a timer, because nothing here is allowed to
  // call into Dart and Dart is not going to ask on the core's behalf.
  //
  // Twenty times a second: fast enough that a keystroke's PRIVMSG does not
  // sit in a queue where a reader would notice, and slow enough to be free.
  setInterval(function () {
    // `wanted` is cleared when a connection ends, so the core decides whether
    // to dial again — through a fresh sign-in — rather than this redialling
    // the last one with a proof that has been spent.
    var want = frq.wanted();
    if (!want && wantedNow) {
      wantedNow = "";
      hangUp();
    } else if (want && want !== wantedNow) {
      wantedNow = want;
      hangUp();
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

  // A picture: chosen with the browser's own file input, and posted to
  // freeq's media endpoint as the multipart form it wants. The URL that
  // comes back goes in the line — that is how a picture travels on IRC.
  //
  // Posted to this server rather than to freeq, and the reason is CORS.
  //
  // freeq's media endpoint answers `access-control-allow-origin` for exactly
  // one origin -- its own -- so a POST straight from here is sent, accepted,
  // and its reply withheld: the picture uploads and the URL naming it never
  // arrives. A URL nobody can read is a picture nobody can see. Nothing on
  // the page can get around that; an `<img>` shows a cross-origin picture
  // because displaying is not reading, and an upload is nothing but reading
  // the answer.
  //
  // `/api/v1/upload` on our own origin is not a circumvention, it is a
  // different request: same-origin, so no preflight and no allowlist.
  // `tools/webserve.py` relays it, from a process the rule does not apply
  // to. One `Access-Control-Allow-Origin: *` on freeq's side would retire
  // the whole arrangement -- and that is now the small ask, because this
  // sends no credentials.
  //
  // Straight to freeq when the page is already on it, where the relay would
  // be a detour through nothing.
  function pickAndUpload(want) {
    var input = document.createElement("input");
    input.type = "file";
    input.accept = "image/*";
    input.onchange = function () {
      var file = input.files && input.files[0];
      if (!file) { frq.dispatch(JSON.stringify({id: "attachment.failed",
                                                value: ""})); return; }
      // The endpoint's own cap, refused here rather than after several
      // megabytes have crossed the wire to be turned down.
      if (file.size > 10 * 1024 * 1024) {
        frq.dispatch(JSON.stringify(
          {id: "attachment.failed:That picture is over the 10MB the server takes."}));
        return;
      }
      var form = new FormData();
      form.append("did", want.did);
      if (want.channel) form.append("channel", want.channel);
      form.append("file", file, file.name || "picture.png");
      var where = window.location.host === want.host
        ? "https://" + want.host + "/api/v1/upload"
        : "/api/v1/upload";
      fetch(where, {method: "POST", body: form})
        .then(function (r) { return r.text().then(function (t) {
          return {ok: r.ok, status: r.status, body: t}; }); })
        .then(function (r) {
          var url = "";
          try { url = JSON.parse(r.body).url || ""; } catch (e) { url = ""; }
          if (r.ok && url) {
            frq.dispatch(JSON.stringify({id: "attachment.ready:" + url}));
          } else {
            frq.dispatch(JSON.stringify({id: "attachment.failed:Upload failed ("
                                             + r.status + ")"}));
          }
        })
        .catch(function (e) {
          frq.dispatch(JSON.stringify({id: "attachment.failed:" +
            String(e && e.message ? e.message : e)}));
        });
    };
    input.click();
  }

  // The sign-in, which this page does itself — see `frq_oauth.js` for why
  // the broker cannot finish one here.
  //
  // Three things it is asked for, each taken as it is read so that asking
  // twice does not do it twice: a sign-in to start, a proof to mint before a
  // connection, and a session to forget.
  setInterval(function () {
    var handle = frq.wantedSignIn();
    if (handle) {
      frqOauth.begin(handle).catch(function (e) {
        frq.signInFailed(String(e && e.message ? e.message : e));
      });
    }
    if (frq.needProof()) {
      frqOauth.prepare().then(
        function (s) {
          // The whole session, not just the proof. `prepare` asks the PDS
          // who the token belongs to, and that answer can be the first time
          // anyone here learns the handle — a sign-in whose `whoami` failed
          // at the time has a session with a token and no name, and a
          // nameless session connects as whatever is in the nick box, which
          // is `frq-guest`. Handing the proof over on its own threw the
          // answer away every time.
          frq.restoreSession(JSON.stringify(s));
          frq.proofReady(s.dpopProof);
        },
        function (e) {
          frq.signInFailed(String(e && e.message ? e.message : e));
          frq.proofReady("");
        });
    }
    if (frq.needForget()) frqOauth.forget();

    var upload = frq.wantedPicture();
    if (upload) pickAndUpload(JSON.parse(upload));
  }, 50);

  frq.init("");

  // Two ways a session arrives, and they mean different things. Coming back
  // from the authorization server is a sign-in the reader asked for and is
  // waiting on, so it connects; finding one in storage at load is not, so it
  // only fills the name in.
  frqOauth.resume().then(
    function (session) {
      if (session) frq.handoff(JSON.stringify(session));
      else {
        var saved = frqOauth.saved();
        if (saved) frq.restoreSession(JSON.stringify(saved));
      }
    },
    function (e) { frq.signInFailed(String(e && e.message ? e.message : e)); });
})();
