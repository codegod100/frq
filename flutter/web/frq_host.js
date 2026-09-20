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

  // A picture: chosen with the browser's own file input, and posted to
  // freeq's media endpoint as the multipart form it wants. The URL that
  // comes back goes in the line — that is how a picture travels on IRC.
  //
  // From a browser this is blocked, and the shape of the block is worth
  // writing down because it is not the one it looks like. freeq does send
  // CORS headers -- `vary: origin`, an allow-methods and an allow-headers --
  // and answers with `access-control-allow-origin: https://irc.freeq.at` for
  // exactly one origin: its own. It is an allowlist, and we are not on it,
  // for this build or the deployed one. Being added is somebody else's
  // decision, the same one as the broker's `return_to` list.
  //
  // Sending no `Authorization` header is what makes it a *simple* request,
  // which means no preflight -- so the POST is not stopped, only the answer
  // is. The picture does upload; the URL naming it is withheld, and a URL
  // nobody can read is a picture nobody can see. The endpoint wants no auth
  // for a public upload (it says "No file provided", not "Unauthorized"),
  // and no credentials are sent, which is deliberate: a request without
  // them can be allowed by a plain `*`, where `credentials: "include"`
  // would oblige the server to name this origin specifically. The smaller
  // ask is the one more likely to be granted.
  //
  // Written the way it will work rather than left out -- the same POST from
  // the desktop build has no such limit.
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
      fetch("https://" + want.host + "/api/v1/upload",
            {method: "POST", body: form})
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
