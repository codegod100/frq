// The browser sign-in, as far as it goes without a reader.
//
//     node nim/web/test/authorize.js [handle]
//
// Not part of `just test web`, which runs offline. This one talks to the real
// network — it resolves a handle, finds the PDS, discovers the authorization
// server and pushes an authorization request — and what it proves is the one
// thing nothing local can: that the authorization server fetches our
// `client-metadata.json` from the deployed origin and accepts it. A
// `request_uri` coming back is that answer.
//
// It stops there. What follows is the reader logging in, which needs their
// credentials and is theirs to do.
//
// Nobody is signed in by this and nothing is spent: PAR happens before any
// login, and the request it pushes expires unused.
const fs = require('fs');
let assigned = '';
// The deployed origin by default; `FRQ_WEB_ORIGIN=http://127.0.0.1:8000` runs
// the same probe as a page served from a developer's own machine, which takes
// the other branch of `clientId` -- the `http://localhost` exception.
const served = new URL(process.env.FRQ_WEB_ORIGIN ||
  'https://codegod100--frq-web-serve.modal.run');
global.window = {
  location: { origin: served.origin, hostname: served.hostname,
              pathname: '/', search: '',
              assign: (u) => { assigned = u; } },
  history: { replaceState() {} },
};
global.localStorage = { _v: {}, getItem(k) { return this._v[k] || null; },
  setItem(k, v) { this._v[k] = String(v); }, removeItem(k) { delete this._v[k]; } };
global.crypto = require('crypto').webcrypto;
global.btoa = (s) => Buffer.from(s, 'binary').toString('base64');
global.TextEncoder = require('util').TextEncoder;
global.URLSearchParams = URLSearchParams;
global.fetch = fetch;

(0, eval)(fs.readFileSync('flutter/web/frq_dpop.js', 'utf8'));
(0, eval)(fs.readFileSync('flutter/web/frq_oauth.js', 'utf8'));

(async () => {
  try {
    await window.frqOauth.begin(process.argv[2] || 'nandi.uk');
    const u = new URL(assigned);
    console.log('authorize host:', u.host + u.pathname);
    console.log('client_id:', u.searchParams.get('client_id'));
    console.log('request_uri:', (u.searchParams.get('request_uri') || '').slice(0, 40) + '…');
    const pending = JSON.parse(localStorage.getItem('frq:oauth:pending'));
    console.log('pending kept:', Object.keys(pending).join(', '));
    console.log('pds:', pending.pds);
  } catch (e) {
    console.log('FAILED:', e.message);
  }
})();
