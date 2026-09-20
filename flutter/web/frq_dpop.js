// DPoP for the browser OAuth client: ES256 keys, proofs, PKCE.
//
// Unchanged from the build before this one, ClojureDart and all: what it does
// is WebCrypto — generateKey, sign, digest, exportKey — and that was already
// JavaScript then for the same reason it is now. Every one of those speaks in
// Promises, ArrayBuffers, JWK objects and algorithm records, and none of that
// crosses a language boundary well. What crosses here is a string.
//
// The Nim core never sees any of this. Signing is asynchronous and the core
// is not, which is the whole reason the browser sign-in lives out here.
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

  // Promises, plainly. This used to hand its answers back through node-style
  // `cb(err, value)` callbacks, for a reason that has gone: the caller was
  // ClojureDart, which could only reach JavaScript through `dart:js` — no
  // `promiseToFuture`, so a thenable could not be awaited from that side. The
  // caller is `frq_oauth.js` now, where a Promise is the native thing to
  // return and `await` is the native thing to do with it.
  window.frqDpop = {
    proof: proof,
    challenge: challenge,
    // Synchronous already: no crypto to await, just random bytes.
    verifier: verifier,
    random: random,
    forget: forget,
  };
})();
