// The service worker, written the other way round from the one we removed.
//
// A browser will not offer to install a page unless it has a worker with a
// fetch handler, so a PWA needs one. Flutter ships such a worker and it is
// the wrong one here: it is offline-first, which means a deploy landed only
// after a new worker had waited for every tab on the origin to close, and
// until then the app went on serving the bundle it had. Twice in one
// afternoon a working fix read as broken because of it.
//
// This one is network-first and takes over at once.
//
// * `skipWaiting` in install and `clients.claim` in activate: no waiting
//   room. A new worker replaces the old one on the next load, not on the
//   next time every tab happens to be closed.
// * every GET goes to the network first, and the cache is what answers when
//   the network does not. So what is served is what was deployed, and the
//   cache is a fallback rather than the source of truth.
//
// What that buys on the install side is the shell: opened from a home
// screen with no connection it draws itself and says it is not connected,
// rather than showing the browser's dinosaur. It cannot do more than that
// and should not pretend to -- this is a window onto a live IRC connection,
// and without the network there is nothing to look at.
const CACHE = "frq-shell-v1";

self.addEventListener("install", () => {
  self.skipWaiting();
});

self.addEventListener("activate", (e) => {
  e.waitUntil((async () => {
    // Anything an older worker left, ours included once the name changes.
    for (const k of await caches.keys()) {
      if (k !== CACHE) await caches.delete(k);
    }
    await self.clients.claim();
  })());
});

self.addEventListener("fetch", (e) => {
  const req = e.request;
  // Only our own GETs. A POST is never replayable, the upload relay least of
  // all, and another origin's bytes are not ours to keep -- the avatars and
  // pictures come from hosts that never agreed to be cached here.
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith("/api/")) return;

  e.respondWith((async () => {
    try {
      const fresh = await fetch(req);
      // Only a real answer is kept. A 404 or a 500 cached is a fault that
      // outlives the deploy that caused it.
      if (fresh && fresh.ok && fresh.type === "basic") {
        const c = await caches.open(CACHE);
        c.put(req, fresh.clone());
      }
      return fresh;
    } catch (err) {
      const kept = await caches.match(req);
      if (kept) return kept;
      throw err;
    }
  })());
});
