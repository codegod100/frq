// Signing in with Bluesky from a page, as an OAuth client of our own.
//
// Not freeq's broker. The broker finishes a login by redirecting to
// `return_to`, and it only redirects to hosts on its own allowlist — loopback
// and its own freeq origins. A build served from anywhere else can never
// finish a sign-in through it, whatever the client does; asking to be added
// to that list is somebody else's decision. The desktop is loopback and is
// fine. This page is not, and said so: `Invalid return_to URL`.
//
// So this does the AT Protocol OAuth itself. What makes that possible is
// whose allowlist applies: an authorization server fetches the client's
// metadata from its `client_id` URL and takes *that document* as the
// authority on where a code may be sent. We serve it — `client-metadata.json`
// beside this file — so the redirect URI is ours to declare.
//
// A public client with no secret, which a page could not keep anyway. What
// stands in for one is DPoP: every token is bound to a key this client proves
// it holds, which is also exactly what freeq's SASL `pds-oauth` verifies — it
// takes the token and a proof, calls the PDS's getSession with both, and
// believes the PDS.
//
// Ported from `flutter/src/frq/oauth/web.cljd`, which did this in
// ClojureDart. The comments that survive are the ones that cost somebody
// something to learn.
//
// The flow is two halves with a page load between them: `begin` leaves for
// the authorization server and does not return, and `resume` runs on the load
// that comes back.

(function () {
  'use strict';

  const dpop = () => window.frqDpop;

  // The app's root, which is both this client's identity and where a code
  // comes back. The origin and a bare slash — deliberately NOT
  // `location.pathname`: both values have to match `client-metadata.json`
  // exactly, and built from the current path a page opened at `/index.html`
  // asks for `/index.htmlclient-metadata.json` and is told, quite correctly,
  // Not Found.
  const origin = () => window.location.origin + '/';

  // Scope is declared in two places and they have to agree: here, where the
  // authorization request asks for it, and in the metadata document, which
  // says what this client may ever ask for.
  const SCOPE = 'atproto transition:generic';

  // A page served from a developer's own machine cannot publish a metadata
  // document that an authorization server can reach, so the spec makes an
  // exception for it: a `client_id` whose origin is exactly `http://localhost`
  // is not fetched at all, and the server builds a virtual document out of the
  // query string instead.
  //
  // Three things about that exception cost a rejection each to learn. The
  // hostname must be the word `localhost` -- `127.0.0.1` is *not* accepted,
  // which is exactly what `Invalid client ID "http://127.0.0.1:8000/..."`
  // was saying. There must be no port and no path, so the `client_id` is
  // `http://localhost` and nothing more before the `?`. And the redirect URI
  // we declare there is matched on its path but *not* on its port, which is
  // the whole point -- a dev server's port is whatever was free.
  //
  // So the redirect stays this page, loopback address and port and all; only
  // the identity is the fiction.
  const loopback = () =>
    /^(localhost|127(\.\d+){3}|\[::1\])$/.test(window.location.hostname);

  const clientId = () =>
    loopback()
      ? 'http://localhost?redirect_uri=' + encodeURIComponent(origin()) +
        '&scope=' + encodeURIComponent(SCOPE)
      : origin() + 'client-metadata.json';

  const PENDING = 'frq:oauth:pending';
  const SESSION = 'frq:oauth:session';

  const load = (k) => {
    try { return JSON.parse(localStorage.getItem(k) || 'null'); }
    catch (e) { return null; }
  };
  const save = (k, v) => {
    try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) { /* private mode */ }
  };
  const drop = (k) => {
    try { localStorage.removeItem(k); } catch (e) { /* nothing to do */ }
  };

  const trimSlash = (s) => String(s).replace(/\/+$/, '');

  // One request, and two things a convenience wrapper would hide: a non-2xx
  // body, and the `DPoP-Nonce` header. Both are load-bearing — an
  // authorization server answers the first request of a flow with 400
  // `use_dpop_nonce` and the nonce to use, and that is not an error, it is
  // the handshake.
  async function http(method, url, headers, body) {
    const r = await fetch(url, { method: method, headers: headers, body: body });
    return {
      status: r.status,
      body: await r.text(),
      nonce: r.headers.get('dpop-nonce') || '',
    };
  }

  const form = (pairs) =>
    pairs.map(([k, v]) => k + '=' + encodeURIComponent(String(v))).join('&');

  // Which server authorizes for this PDS.
  //
  // Two shapes, and the difference is what a real account runs into. A PDS
  // shard — `puffball.us-east.host.bsky.network` and its siblings —
  // publishes `oauth-protected-resource` naming `https://bsky.social` as its
  // authorization server, and serves no authorization-server metadata of its
  // own. An all-in-one host like bsky.social IS the authorization server and
  // publishes no protected-resource document at all.
  //
  // So ask for the pointer, and fall back to the PDS itself when there is
  // none. Testing against bsky.social alone hid this entirely — the first
  // real handle went to a shard and stopped dead.
  async function authServer(base) {
    try {
      const r = await http('GET', base + '/.well-known/oauth-protected-resource', {}, null);
      if (r.status === 200) {
        const list = JSON.parse(r.body).authorization_servers;
        if (list && list.length) return list[0];
      }
    } catch (e) { /* fall through to the PDS itself */ }
    return base;
  }

  async function discover(pds) {
    const base = trimSlash(pds);
    const as = trimSlash(await authServer(base));
    const r = await http('GET', as + '/.well-known/oauth-authorization-server', {}, null);
    if (r.status !== 200) throw new Error('No OAuth metadata at ' + as);
    const m = JSON.parse(r.body);
    return {
      par: m.pushed_authorization_request_endpoint,
      authorize: m.authorization_endpoint,
      token: m.token_endpoint,
    };
  }

  // POST a form with a freshly minted proof, retrying once when the server
  // asks for a nonce. The retry is the protocol and not a fallback: a client
  // has no way to know the first nonce, so the first request of every flow is
  // answered with 400 `use_dpop_nonce` and the nonce to use.
  async function postForm(url, body, token) {
    const send = async (nonce) => {
      const p = await dpop().proof('POST', url, nonce, token || '');
      return http('POST', url,
        { 'Content-Type': 'application/x-www-form-urlencoded', 'DPoP': p }, body);
    };
    const first = await send('');
    if (first.status >= 400 && first.body.includes('use_dpop_nonce') && first.nonce) {
      return send(first.nonce);
    }
    return first;
  }

  // An authenticated GET carrying a proof, retrying once for a nonce — the
  // same handshake one method over. A PDS answers the first
  // DPoP-authenticated request of a session with 401 and the nonce it wants.
  async function getWithDpop(url, token, nonce) {
    const p = await dpop().proof('GET', url, nonce || '', token);
    const r = await http('GET', url,
      { 'Authorization': 'DPoP ' + token, 'DPoP': p }, null);
    if (r.status >= 400 && r.body.includes('use_dpop_nonce') && r.nonce && !nonce) {
      return getWithDpop(url, token, r.nonce);
    }
    return r;
  }

  const sessionUrl = (pds) => trimSlash(pds) + '/xrpc/com.atproto.server.getSession';

  // OAuth access tokens are JWTs.  Looking at `exp` locally does not prove a
  // token is valid (only the PDS can do that), but it does prove that one is
  // not: sending a token that is already past its expiry only creates a
  // predictable 401 before the refresh flow starts.  Leave opaque or
  // malformed tokens to the PDS so this remains an optimisation, not a
  // second validator.
  function expiredJwt(token) {
    try {
      const part = String(token).split('.')[1];
      if (!part) return false;
      const padded = part.replace(/-/g, '+').replace(/_/g, '/') +
        '==='.slice((part.length + 3) % 4);
      const claims = JSON.parse(atob(padded));
      // A small margin avoids racing the PDS at the expiry boundary.
      return typeof claims.exp === 'number' && claims.exp * 1000 <= Date.now() + 30000;
    } catch (e) {
      return false;
    }
  }

  // Who the token belongs to, asked of the PDS. Three things at once, which
  // is why it is worth a round trip.
  //
  // It settles the handle — the token response carries `sub`, a DID, and
  // nothing a person would recognise, and without a handle there is no nick
  // to derive, which is how an OAuth sign-in once arrived on the server
  // calling itself `frq-guest`.
  //
  // It proves the proof is accepted before one is handed to freeq, since this
  // is the very call freeq will make with it. And it collects the nonce the
  // PDS wants, so the proof minted at connect carries one already.
  //
  // It fails loudly, and that is the third thing. A refusal here used to
  // return null and let the sign-in carry on with whatever the token
  // response happened to say, which is how a rejected token became a guest
  // on the server with no word about why -- and, from the outside, an
  // unexplained 401 in the console. Whoever the PDS will not vouch for is
  // not signed in.
  async function whoami(pds, token) {
    const r = await getWithDpop(sessionUrl(pds), token, '');
    if (r.status !== 200) {
      // Said twice on purpose. The throw reaches the reader as the app's own
      // warning; this puts the same words in the console, which is where a
      // refusal is looked at -- and where, until it was printed, there was a
      // bare `401 (Unauthorized)` and no way to tell an expired token from a
      // wrong one.
      console.warn('frq: getSession refused', r.status, r.body);
      throw new Error('The PDS would not accept the token (' + r.status +
        '): ' + r.body);
    }
    const j = JSON.parse(r.body);
    return { handle: j.handle || '', did: j.did || '', nonce: r.nonce || '' };
  }

  // Resolving an identity. The same two steps `frq/atproto.nim` takes on the
  // desktop, in the language that has `fetch`.
  async function resolveHandle(handle) {
    const h = String(handle).trim().replace(/^@/, '');
    const r = await http('GET',
      'https://public.api.bsky.app/xrpc/com.atproto.identity.resolveHandle?handle=' +
      encodeURIComponent(h), {}, null);
    if (r.status !== 200) throw new Error('Could not resolve ' + h);
    return JSON.parse(r.body).did;
  }

  async function pdsFor(did) {
    const url = did.startsWith('did:plc:')
      ? 'https://plc.directory/' + did
      : 'https://' + did.replace(/^did:web:/, '') + '/.well-known/did.json';
    const r = await http('GET', url, {}, null);
    if (r.status !== 200) throw new Error('Could not look up ' + did);
    const doc = JSON.parse(r.body);
    for (const svc of doc.service || []) {
      if (svc.type === 'AtprotoPersonalDataServer') return svc.serviceEndpoint;
    }
    throw new Error('No PDS endpoint for ' + did);
  }

  // Push the request, then leave for the authorization server.
  //
  // PAR and not a plain authorize URL: `require_pushed_authorization_requests`
  // is true at bsky.social, so the parameters go up over the back channel
  // first and the browser carries only the `request_uri` that comes back.
  async function begin(handle) {
    const did = await resolveHandle(handle);
    const pds = await pdsFor(did);
    const ends = await discover(pds);
    const verifier = dpop().verifier();
    const challenge = await dpop().challenge(verifier);
    const state = dpop().random(16);

    const body = form([
      ['client_id', clientId()],
      ['redirect_uri', origin()],
      ['response_type', 'code'],
      ['scope', SCOPE],
      ['state', state],
      ['code_challenge', challenge],
      ['code_challenge_method', 'S256'],
      // A hint and not an assertion — the reader still chooses at the
      // authorization page.
      ['login_hint', handle],
    ]);
    const r = await postForm(ends.par, body, null);
    if (r.status !== 201) throw new Error('Authorization request refused: ' + r.body);

    const requestUri = JSON.parse(r.body).request_uri;
    save(PENDING, { verifier, state, did, handle, pds, token: ends.token });
    window.location.assign(
      ends.authorize + '?client_id=' + encodeURIComponent(clientId()) +
      '&request_uri=' + encodeURIComponent(requestUri));
  }

  // Finish a sign-in that left this page and came back. Returns the session,
  // or null when this load is not one.
  async function resume() {
    const params = new URLSearchParams(window.location.search);
    const code = params.get('code');
    const state = params.get('state');
    const pending = load(PENDING);
    if (!code || !pending) return null;

    // `replaceState` rather than assigning to `location`, which would push a
    // history entry and leave a Back button that redeems a spent code.
    try { history.replaceState(null, '', origin()); } catch (e) { /* nothing */ }

    // State is the CSRF binding: a code arriving with a state we did not
    // issue is not ours, and redeeming it would be the attack this prevents.
    if (state !== pending.state) throw new Error('state did not match');

    const r = await postForm(pending.token, form([
      ['grant_type', 'authorization_code'],
      ['code', code],
      ['redirect_uri', origin()],
      ['client_id', clientId()],
      ['code_verifier', pending.verifier],
    ]), null);
    if (r.status !== 200) throw new Error('Sign-in failed: ' + r.body);

    const t = JSON.parse(r.body);

    // What was granted, which is not always what was asked for. The profile
    // requires servers to return the granted scopes and clients to reject a
    // response without `atproto` -- and the failure this catches is the
    // quiet one: a token granted a narrower scope than requested works for
    // nothing and says so only much later, as a 401 from the PDS with no
    // hint that a scope was the reason.
    const granted = String(t.scope || '').split(/\s+/);
    if (!granted.includes('atproto')) {
      throw new Error('Signed in without the atproto scope: ' +
        (t.scope || 'none granted'));
    }

    const who = await whoami(pending.pds, t.access_token);
    const session = {
      did: who.did || t.sub || pending.did,
      handle: who.handle || pending.handle || '',
      accessJwt: t.access_token,
      refresh: t.refresh_token || '',
      pds: pending.pds,
      // Where a refresh goes. Discovery would find it again, but it is two
      // round trips to learn something already known, on the path taken
      // every time the app opens.
      token: pending.token,
      dpopNonce: who.nonce || '',
    };
    drop(PENDING);
    save(SESSION, session);
    return session;
  }

  const saved = () => load(SESSION);

  function forget() {
    drop(SESSION);
    drop(PENDING);
    // A DPoP key outliving the token it was bound to is a key with nothing
    // to prove.
    dpop().forget();
  }

  // Trade the refresh token for a fresh access token.
  //
  // This was the missing half of the session: `resume` stored a
  // `refresh_token` and nothing ever spent it. An access token is good for
  // minutes -- the profile says under thirty and recommends five -- so a
  // reader who signed in and came back an hour later had a session that
  // looked complete, a PDS that refused it, and a client that shrugged and
  // connected as a guest.
  //
  // The new refresh token replaces the old one and the old one is spent:
  // they are single-use, so it is saved before anything else can fail.
  async function refresh() {
    const s = saved();
    if (!s || !s.refresh) throw new Error('not signed in');
    const where = s.token || (await discover(s.pds)).token;
    const r = await postForm(where, form([
      ['grant_type', 'refresh_token'],
      ['refresh_token', s.refresh],
      ['client_id', clientId()],
    ]), null);
    if (r.status !== 200) {
      // The refresh token is gone or was revoked, and no retry will bring it
      // back. Clearing the session is what turns "signed in, and nothing
      // works" into a sign-in button.
      console.warn('frq: refresh refused', r.status, r.body);
      forget();
      throw new Error('The session has expired; sign in again (' +
        r.status + '): ' + r.body);
    }
    const t = JSON.parse(r.body);
    s.accessJwt = t.access_token;
    if (t.refresh_token) s.refresh = t.refresh_token;
    s.token = where;
    save(SESSION, s);
    return s;
  }

  // Mint the proof freeq will present to the PDS on our behalf.
  //
  // For `GET {pds}/xrpc/com.atproto.server.getSession` and bound to the
  // access token, because that is the exact request freeq makes with it.
  // Minted per connect: a proof has an `iat` and a single-use `jti`, so one
  // kept from sign-in would be refused by the time a reconnect offered it.
  //
  // The token is asked about first, for the reason the ClojureDart did: an
  // access token lives about an hour, and the only thing that comes back
  // through IRC when it has expired is a bare failure.
  async function prepare() {
    let s = saved();
    if (!s) throw new Error('not signed in');
    let who;
    if (expiredJwt(s.accessJwt)) {
      // `exp` is definitive, so do not ask the PDS to reject this token
      // merely to learn what the browser already knows.
      s = await refresh();
      who = await whoami(s.pds, s.accessJwt);
    } else try {
      who = await whoami(s.pds, s.accessJwt);
    } catch (e) {
      // Asking who the token belongs to is also how its age is discovered.
      // A refusal here is nearly always an expired access token, so spend
      // the refresh token and ask once more; if that fails it throws, and
      // saying so beats connecting as somebody else.
      s = await refresh();
      who = await whoami(s.pds, s.accessJwt);
    }
    if (who.handle) s.handle = who.handle;
    if (who.did) s.did = who.did;
    if (who.nonce) s.dpopNonce = who.nonce;
    save(SESSION, s);
    s.dpopProof = await dpop().proof(
      'GET', sessionUrl(s.pds), s.dpopNonce || '', s.accessJwt);
    return s;
  }

  window.frqOauth = { begin, resume, saved, forget, prepare, refresh };
})();
