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

// The browser sign-in: the core asks the host to do the asynchronous parts
// and takes the answers back. None of this can be reached from the Nim suite,
// because the whole point of the seam is that the other side is JavaScript.
frq.demo();
frq.dispatch(JSON.stringify({ id: "screen.connect" }));
frq.dispatch(JSON.stringify({ id: "mode.bluesky" }));
frq.dispatch(JSON.stringify({ id: "handle.change", value: "alice.bsky.social" }));
frq.dispatch(JSON.stringify({ id: "connect" }));
check("with no session, it asks the host to sign in",
      frq.wantedSignIn() === "alice.bsky.social");
check("and asks only once", frq.wantedSignIn() === "");

// A session the host already had: the name appears, and nothing connects.
frq.restoreSession(JSON.stringify({
  did: "did:plc:abc", handle: "alice.bsky.social",
  accessJwt: "tok", pds: "https://pds.example", dpopNonce: "n1",
}));
// `wanted` is the last socket the core asked for and stays set, which is how
// the host knows not to redial — so "did it dial" is a comparison.
const dialledBefore = frq.wanted();
check("a stored session does not connect by itself",
      frq.wanted() === dialledBefore);
check("but it does put the handle on the screen",
      frq.render().includes("alice.bsky.social"));

// Now Connect: the proof is the last thing it waits for.
frq.dispatch(JSON.stringify({ id: "connect" }));
check("with a session, it asks for a proof", frq.needProof() === true);
check("and asks only once", frq.needProof() === false);
check("nothing is dialled until the proof is in",
      frq.wanted() === dialledBefore);
frq.proofReady("eyJhbGciOiJFUzI1NiJ9.proof");
check("the proof opens the socket", JSON.parse(frq.wanted() || "{}").host === "irc.freeq.at");

// And the SASL payload carries it. Drained at every step rather than at the
// end: the core answers each line as it arrives, and a single take at the
// end would mix the registration in with the answer being checked.
frq.socketEvent("open");
frq.render();
frq.takeOutbound();                       // CAP LS, NICK, USER
frq.feed("CAP * LS :sasl message-tags server-time");
frq.render();
frq.takeOutbound();                       // CAP REQ
frq.feed("CAP * ACK :sasl message-tags server-time");
frq.render();
check("an acked sasl starts the exchange",
      frq.takeOutbound().trim() === "AUTHENTICATE ATPROTO-CHALLENGE");

const challenge = Buffer.from(JSON.stringify({ nonce: "N1" })).toString("base64url");
frq.feed("AUTHENTICATE " + challenge);
frq.render();
const answer = frq.takeOutbound().trim();
let payload = null;
try {
  payload = JSON.parse(
    Buffer.from(answer.replace("AUTHENTICATE ", ""), "base64url").toString());
} catch (e) { /* left null, and the checks below say so */ }
check("the SASL payload is pds-oauth", payload && payload.method === "pds-oauth");
check("with the DID and the token the host holds",
      payload && payload.did === "did:plc:abc" && payload.signature === "tok");
check("the proof freeq will present to the PDS",
      payload && payload.dpop_proof === "eyJhbGciOiJFUzI1NiJ9.proof");
check("and the nonce it was challenged with",
      payload && payload.challenge_nonce === "N1");

// The connection drops after a quiet spell. Redialling it as it was is what
// signed a reader in as a guest: the proof above is single-use and spent,
// and the access token behind it may have expired while nobody was looking.
frq.feed(":irc.freeq.at 001 alice.bsky.social :Welcome");
frq.render();
frq.takeOutbound();
frq.socketEvent("close: idle");
frq.render();
check("a dropped socket is not redialled as it was", frq.wanted() === "");
check("it asks for a fresh proof instead", frq.needProof() === true);
frq.restoreSession(JSON.stringify({
  did: "did:plc:abc", handle: "alice.bsky.social",
  accessJwt: "tok2", pds: "https://pds.example", dpopNonce: "n2",
}));
frq.proofReady("eyJhbGciOiJFUzI1NiJ9.proof2");
check("and the fresh proof opens the socket again",
      JSON.parse(frq.wanted() || "{}").host === "irc.freeq.at");
frq.socketEvent("open");
frq.render();
frq.takeOutbound();
frq.feed("CAP * LS :sasl");
frq.render();
frq.takeOutbound();
frq.feed("CAP * ACK :sasl");
frq.render();
frq.takeOutbound();
frq.feed("AUTHENTICATE " + challenge);
frq.render();
let again = null;
try {
  again = JSON.parse(Buffer.from(
    frq.takeOutbound().trim().replace("AUTHENTICATE ", ""), "base64url").toString());
} catch (e) { /* left null */ }
check("the reconnect signs in with the renewed token and proof",
      again && again.signature === "tok2" &&
      again.dpop_proof === "eyJhbGciOiJFUzI1NiJ9.proof2");

// Disconnect is the reader leaving, and nothing dials them back in.
frq.dispatch(JSON.stringify({ id: "disconnect" }));
frq.render();
check("a disconnect is not answered with a reconnect",
      frq.wanted() === "" && frq.needProof() === false);

console.log(failures === 0 ? "all ok" : failures + " failed");
process.exit(failures === 0 ? 0 : 1);
