// The web core, driven the way a browser drives it.
//
// Not a unit test — the Nim suite is that, and it covers the same reducer
// this runs. What is checked here is the seam: that the JavaScript build
// loads, that a tree comes out as JSON, that an event goes in, and that a
// line fed in as if from a socket reaches the screen. Those are the four
// things that can break without a single Nim test noticing, because the
// desktop build does them through a different file.
//
//   node nim/web/test/smoke.js build/web/frq_core.js

const fs = require('fs');
const path = process.argv[2] || 'build/web/frq_core.js';

// The bits of a browser this build touches. The core asks localStorage for a
// saved session and asks `location` where to send a reader for sign-in.
globalThis.window = {
  localStorage: {
    _v: {},
    getItem(k) { return this._v[k] || ""; },
    setItem(k, v) { this._v[k] = String(v); return true; },
    removeItem(k) { delete this._v[k]; },
  },
  location: { href: "", origin: "http://localhost", pathname: "/" },
};

// Global scope, not a module's: the core puts `frq` on globalThis, and a
// `require` would wrap it where nothing could see it.
(0, eval)(fs.readFileSync(path, 'utf8'));

let failures = 0;
function check(what, ok) {
  console.log((ok ? "  ok   " : "  FAIL ") + what);
  if (!ok) failures++;
}

frq.init("");
check("the connect screen renders", JSON.parse(frq.render()).tag === "page");

frq.demo();
check("the demo room renders", frq.render().includes("hello there"));

const chats = frq.dispatch(JSON.stringify({ id: "screen.chats" }));
check("an event answers with the tree it produced", chats.includes("#test"));

// Connecting: the core asks to be dialled rather than dialling.
frq.dispatch(JSON.stringify({ id: "screen.connect" }));
frq.dispatch(JSON.stringify({ id: "nick.change", value: "webtester" }));
frq.dispatch(JSON.stringify({ id: "connect" }));
const wanted = JSON.parse(frq.wanted() || "{}");
check("it asks the host for a socket", wanted.host === "irc.freeq.at" && wanted.tls === true);

// The host says the socket opened; the core answers with registration.
frq.socketEvent("open");
frq.render();
const out = frq.takeOutbound().split("\n");
check("registration goes out on open",
      out[0] === "CAP LS 302" && out[1] === "NICK webtester");
check("and is taken once", frq.takeOutbound() === "");

// A line arrives.
frq.feed(":irc.freeq.at 001 webtester :Welcome");
frq.feed(":alice!a@h PRIVMSG #test :hello from the web");
const tree = frq.render();
check("a fed line reaches the screen", tree.includes("hello from the web"));

// What is saved is saved.
check("the store writes through localStorage",
      Object.keys(window.localStorage._v).some(k => k.startsWith("frq.")));

console.log(failures === 0 ? "all ok" : failures + " failed");
process.exit(failures === 0 ? 0 : 1);
