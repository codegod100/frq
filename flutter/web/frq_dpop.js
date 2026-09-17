// DPoP for the browser OAuth client: ES256 keys, proofs, PKCE.
//
// JavaScript rather than ClojureDart, deliberately. What this does is
// WebCrypto — generateKey, sign, digest, exportKey — and every one of those
// speaks in Promises, ArrayBuffers, JWK objects and JS algorithm records.
// Reaching them from cljd means dart:js_util for each value in both
// directions, and ArrayBuffer-to-bytes is the kind of conversion that fails
// at run time rather than at the compiler. Here it is the language's home
// ground, and what crosses the boundary is a string.
//
// So the contract is narrow on purpose: every function below takes strings
// and returns a string or a Promise of one. `frq.dpop.web` is the other half.
(function () {
  'use strict';

  const enc = new TextEncoder();

  const b64u = (buf) =>
    btoa(String.fromCharCode(...new Uint8Array(buf)))
      .replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');

  const ALG = { name: 'ECDSA', namedCurve: 'P-256' };
  const SIGN = { name: 'ECDSA', hash: 'SHA-256' };

  // The key pair this client proves it holds. One per sign-in, and it must
  // outlive a full-page redirect — the authorization leg leaves for the PDS
  // and comes back as a fresh load — so it is kept as JWK in localStorage
  // rather than as a non-extractable CryptoKey in IndexedDB.
  //
  // That is a deliberate trade and worth naming: an extractable key sits
  // beside the access token it is bound to, in the same store, and anything
  // that can read one can read the other. They share a lifetime and a blast
  // radius, so the key being extractable costs nothing the token does not
  // already cost — and IndexedDB interop through cljd would cost a great deal.
  const KEY = 'frq:dpop:jwk';

  let cached = null;

  async function keys() {
    if (cached) return cached;
    let jwk = null;
    try { jwk = JSON.parse(localStorage.getItem(KEY)); } catch (e) { jwk = null; }
    if (!jwk) {
      const kp = await crypto.subtle.generateKey(ALG, true, ['sign', 'verify']);
      jwk = await crypto.subtle.exportKey('jwk', kp.privateKey);
      try { localStorage.setItem(KEY, JSON.stringify(jwk)); } catch (e) { /* private mode */ }
    }
    const priv = await crypto.subtle.importKey('jwk', jwk, ALG, true, ['sign']);
    // The public half of the same key, which is what a proof carries in its
    // header. Derived from the private JWK by dropping the private fields
    // rather than exported separately, so the two cannot drift apart.
    const pub = { kty: jwk.kty, crv: jwk.crv, x: jwk.x, y: jwk.y };
    cached = { priv, pub };
    return cached;
  }

  async function jws(header, payload, priv) {
    const h = b64u(enc.encode(JSON.stringify(header)));
    const p = b64u(enc.encode(JSON.stringify(payload)));
    // WebCrypto signs ECDSA as raw R||S, which is exactly what JOSE wants —
    // no DER unwrapping, unlike most non-browser crypto libraries.
    const sig = await crypto.subtle.sign(SIGN, priv, enc.encode(h + '.' + p));
    return h + '.' + p + '.' + b64u(sig);
  }

  // One DPoP proof. `nonce` and `token` may be empty strings — cljd has no
  // convenient undefined, and an empty string is the honest "not this time".
  //
  // `ath` is the access token's SHA-256, and it is what lets a proof be
  // minted for a request this client will never make: freeq's SASL calls the
  // PDS's getSession on our behalf, with our token and our proof, and the PDS
  // checks that the proof names that token and that URL.
  async function proof(htm, htu, nonce, token) {
    const { priv, pub } = await keys();
    const payload = {
      jti: crypto.randomUUID(),
      htm: htm,
      htu: htu,
      iat: Math.floor(Date.now() / 1000),
    };
    if (nonce) payload.nonce = nonce;
    if (token) {
      payload.ath = b64u(await crypto.subtle.digest('SHA-256', enc.encode(token)));
    }
    return jws({ typ: 'dpop+jwt', alg: 'ES256', jwk: pub }, payload, priv);
  }

  // PKCE. The verifier is kept by the caller (it has to survive the redirect
  // and `frq.io` already knows how to keep things); this only makes the pair.
  function verifier() {
    return b64u(crypto.getRandomValues(new Uint8Array(32)));
  }

  async function challenge(verifier) {
    return b64u(await crypto.subtle.digest('SHA-256', enc.encode(verifier)));
  }

  function random(n) {
    return b64u(crypto.getRandomValues(new Uint8Array(n)));
  }

  // Forget the key. Called when a session is dropped: a DPoP key outliving
  // the token it was bound to is a key with nothing to prove.
  function forget() {
    cached = null;
    try { localStorage.removeItem(KEY); } catch (e) { /* nothing to do */ }
  }

  // Callbacks rather than Promises, and node-style `cb(err, value)`.
  //
  // ClojureDart can only reach JavaScript through `dart:js` here: cljd's
  // analyzer resolves that library and neither `dart:js_util` nor
  // `dart:js_interop` ("Can't find Dart lib"), so there is no
  // `promiseToFuture` to turn a thenable into a Future. What `dart:js` does
  // give is automatic wrapping of a Dart closure passed as an argument — so
  // the Promise is unwrapped on this side and the answer handed back through
  // a function call, which crosses the boundary cleanly.
  const cbify = (fn) => (...args) => {
    const cb = args.pop();
    Promise.resolve(fn(...args)).then(
      (v) => cb('', v),
      (e) => cb(String(e && e.message ? e.message : e), ''),
    );
  };

  window.frqDpop = {
    proof: cbify(proof),
    challenge: cbify(challenge),
    // Synchronous already: no crypto to await, just random bytes.
    verifier: verifier,
    random: random,
    forget: forget,
  };
})();
