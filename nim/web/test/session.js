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
let sessionCalls = 0;
let tokenProofNonce = '';
let sessionProofNonce = '';
let challengeToken = false;
let challengeSession = false;
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
    sessionCalls += 1;
    const proof = opts.headers.DPoP.split('.')[1];
    sessionProofNonce = JSON.parse(Buffer.from(proof, 'base64url')).nonce || '';
    const bearer = (opts.headers.Authorization || '').replace('DPoP ', '');
    if (bearer !== live) return reply(401, { error: 'InvalidToken' });
    if (challengeSession) {
      challengeSession = false;
      return reply(401, { error: 'use_dpop_nonce' },
                   { 'dpop-nonce': 'rotated-pds-nonce' });
    }
    return reply(200, { did: 'did:plc:abc', handle: 'someone.example' },
                 { 'dpop-nonce': 'n1' });
  }
  if (String(url).endsWith('/token')) {
    const proof = opts.headers.DPoP.split('.')[1];
    tokenProofNonce = JSON.parse(Buffer.from(proof, 'base64url')).nonce || '';
    assert.ok(body.includes('grant_type=refresh_token'), 'a refresh grant');
    assert.ok(body.includes('refresh_token=r1'), 'spends the stored token');
    if (challengeToken) {
      challengeToken = false;
      return reply(400, { error: 'use_dpop_nonce' },
                   { 'dpop-nonce': 'new-as-nonce' });
    }
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

const jwt = (claims) => 'header.' +
  Buffer.from(JSON.stringify(claims)).toString('base64url') + '.signature';

(async () => {
  // A token the PDS still accepts is used as it is.
  store = {}; live = 'fresh-token'; refreshes = 0;
  localStorage.setItem('frq:oauth:session',
    JSON.stringify(session({ dpopNonce: 'saved-pds-nonce' })));
  let s = await window.frqOauth.prepare();
  assert.equal(refreshes, 0);
  assert.ok(s.dpopProof, 'a proof for freeq to present');
  ok('a live token is not refreshed');

  assert.equal(sessionProofNonce, 'saved-pds-nonce');
  ok('and a known PDS nonce avoids another challenge');

  // The nonce the PDS asked for is kept, so the proof minted at connect
  // carries one already.
  assert.equal(window.frqOauth.saved().dpopNonce, 'n1');
  ok('and the nonce it answered with is kept');

  // The case that was silently broken.
  store = {}; live = 'fresh-token'; refreshes = 0; refreshValid = true;
  tokenProofNonce = '';
  localStorage.setItem('frq:oauth:session',
    JSON.stringify(session({ accessJwt: 'stale', tokenNonce: 'as-nonce' })));
  s = await window.frqOauth.prepare();
  assert.equal(refreshes, 1, 'the refresh token was spent');
  assert.equal(s.accessJwt, 'second-token');
  assert.equal(s.handle, 'someone.example', 'still knows who it is');
  ok('a token the PDS refuses is refreshed, once');

  assert.equal(tokenProofNonce, 'as-nonce');
  ok('and refresh reuses the authorization server nonce');

  // Single-use: the replacement is stored, or the next refresh spends a
  // token that is already gone.
  assert.equal(window.frqOauth.saved().refresh, 'r2');
  ok('and the new refresh token replaces the spent one');

  // The token endpoint's nonce challenge is not an authentication failure:
  // mint a new proof with its nonce and immediately retry the same grant.
  store = {}; live = 'fresh-token'; refreshes = 0; refreshValid = true;
  challengeToken = true; tokenProofNonce = '';
  localStorage.setItem('frq:oauth:session',
    JSON.stringify(session({ accessJwt: 'stale', tokenNonce: '' })));
  s = await window.frqOauth.prepare();
  assert.equal(refreshes, 1, 'refresh succeeds after the nonce challenge');
  assert.equal(tokenProofNonce, 'new-as-nonce');
  assert.equal(window.frqOauth.saved().tokenNonce, 'new-as-nonce');
  ok('a token nonce challenge regenerates the proof and retries once');

  // A stored nonce may be rotated by the PDS. Its 401 challenge replaces the
  // stale nonce rather than turning a valid session into a refresh attempt.
  store = {}; live = 'fresh-token'; refreshes = 0; challengeSession = true;
  localStorage.setItem('frq:oauth:session',
    JSON.stringify(session({ dpopNonce: 'stale-pds-nonce' })));
  s = await window.frqOauth.prepare();
  assert.equal(refreshes, 0);
  assert.equal(sessionProofNonce, 'rotated-pds-nonce');
  assert.equal(window.frqOauth.saved().dpopNonce, 'n1');
  ok('a rotated PDS nonce regenerates the proof and retries once');

  // Expired JWTs are refreshed without the otherwise inevitable failed PDS
  // request.  The PDS remains the authority for a token that is unexpired
  // but revoked, so only a locally definitive expiry takes this path.
  store = {}; live = 'fresh-token'; refreshes = 0; sessionCalls = 0;
  localStorage.setItem('frq:oauth:session',
    JSON.stringify(session({ accessJwt: jwt({ exp: 1 }) })));
  s = await window.frqOauth.prepare();
  assert.equal(refreshes, 1, 'an expired JWT refreshes immediately');
  assert.equal(sessionCalls, 1, 'only the fresh token reaches the PDS');
  ok('an expired JWT does not create a predictable PDS 401');

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
