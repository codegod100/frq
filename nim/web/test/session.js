// The sign-in that outlives its access token.
//
//     node nim/web/test/session.js
//
// Offline: `fetch` is a stub here and no network is touched. What it covers
// is the half of the session that had no caller -- `resume` stored a
// `refresh_token` and nothing ever spent it, so a reader who came back an
// hour later held a session that looked complete and a PDS that refused it.
// An access token is good for minutes; the app is open for longer.
const fs = require('fs');
const assert = require('assert');

let store = {};
global.localStorage = {
  getItem(k) { return k in store ? store[k] : null; },
  setItem(k, v) { store[k] = String(v); },
  removeItem(k) { delete store[k]; },
};
global.window = {
  location: { origin: 'http://127.0.0.1:8000', hostname: '127.0.0.1',
              pathname: '/', search: '', assign() {} },
  history: { replaceState() {} },
};
global.crypto = require('crypto').webcrypto;
global.btoa = (s) => Buffer.from(s, 'binary').toString('base64');
global.TextEncoder = require('util').TextEncoder;
global.URLSearchParams = URLSearchParams;

// The PDS and the authorization server, as far as this cares: an access
// token is accepted only while it is the current one.
let live = 'fresh-token';
let refreshes = 0;
let refreshValid = true;
const calls = [];
global.fetch = async (url, opts) => {
  const body = String((opts && opts.body) || '');
  calls.push(String(url));
  const reply = (status, obj, headers) => ({
    status: status,
    text: async () => JSON.stringify(obj),
    headers: { get: (h) => (headers || {})[h.toLowerCase()] || null },
  });
  if (String(url).endsWith('/xrpc/com.atproto.server.getSession')) {
    const bearer = (opts.headers.Authorization || '').replace('DPoP ', '');
    if (bearer !== live) return reply(401, { error: 'InvalidToken' });
    return reply(200, { did: 'did:plc:abc', handle: 'someone.example' },
                 { 'dpop-nonce': 'n1' });
  }
  if (String(url).endsWith('/token')) {
    assert.ok(body.includes('grant_type=refresh_token'), 'a refresh grant');
    assert.ok(body.includes('refresh_token=r1'), 'spends the stored token');
    if (!refreshValid) return reply(400, { error: 'invalid_grant' });
    refreshes += 1;
    live = 'second-token';
    return reply(200, { access_token: live, refresh_token: 'r2',
                        scope: 'atproto transition:generic' });
  }
  throw new Error('unexpected request: ' + url);
};

(0, eval)(fs.readFileSync('flutter/web/frq_dpop.js', 'utf8'));
(0, eval)(fs.readFileSync('flutter/web/frq_oauth.js', 'utf8'));

const ok = (name) => console.log('  ok   ' + name);
const session = (over) => Object.assign({
  did: 'did:plc:abc', handle: 'someone.example', accessJwt: 'fresh-token',
  refresh: 'r1', pds: 'https://pds.example',
  token: 'https://pds.example/token', dpopNonce: '',
}, over || {});

(async () => {
  // A token the PDS still accepts is used as it is.
  store = {}; live = 'fresh-token'; refreshes = 0;
  localStorage.setItem('frq:oauth:session', JSON.stringify(session()));
  let s = await window.frqOauth.prepare();
  assert.equal(refreshes, 0);
  assert.ok(s.dpopProof, 'a proof for freeq to present');
  ok('a live token is not refreshed');

  // The nonce the PDS asked for is kept, so the proof minted at connect
  // carries one already.
  assert.equal(window.frqOauth.saved().dpopNonce, 'n1');
  ok('and the nonce it answered with is kept');

  // The case that was silently broken.
  store = {}; live = 'fresh-token'; refreshes = 0; refreshValid = true;
  localStorage.setItem('frq:oauth:session',
    JSON.stringify(session({ accessJwt: 'stale' })));
  s = await window.frqOauth.prepare();
  assert.equal(refreshes, 1, 'the refresh token was spent');
  assert.equal(s.accessJwt, 'second-token');
  assert.equal(s.handle, 'someone.example', 'still knows who it is');
  ok('a token the PDS refuses is refreshed, once');

  // Single-use: the replacement is stored, or the next refresh spends a
  // token that is already gone.
  assert.equal(window.frqOauth.saved().refresh, 'r2');
  ok('and the new refresh token replaces the spent one');

  // No refresh left. Connecting as a guest here is the bug this is named
  // after; the session goes and the reader is asked to sign in.
  store = {}; live = 'fresh-token'; refreshValid = false;
  localStorage.setItem('frq:oauth:session',
    JSON.stringify(session({ accessJwt: 'stale' })));
  let threw = '';
  try { await window.frqOauth.prepare(); } catch (e) { threw = String(e); }
  assert.ok(/expired/.test(threw), 'says so: ' + threw);
  assert.equal(window.frqOauth.saved(), null, 'and the session is cleared');
  ok('a refusal that no refresh fixes ends the session, loudly');

  console.log('all ok');
})().catch((e) => { console.error(e); process.exit(1); });
