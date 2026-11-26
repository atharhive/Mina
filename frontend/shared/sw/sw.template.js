// Keeps one application available without a network. APP, BASE, VERSION and ASSETS are filled
// in at build time. API requests (/v1) are never cached: an answer must come from the server.
const PREFIX = `mina-${APP}-`;
const CACHE = PREFIX + VERSION;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((c) => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});
self.addEventListener("activate", (event) => {
  // only this application's old caches: others on the same server keep theirs
  event.waitUntil(caches.keys()
    .then((names) => Promise.all(names.filter((n) => n.startsWith(PREFIX) && n !== CACHE).map((n) => caches.delete(n))))
    .then(() => self.clients.claim()));
});
self.addEventListener("fetch", (event) => {
  const url = new URL(event.request.url);
  if (event.request.method !== "GET" || url.origin !== location.origin || url.pathname.startsWith("/v1/")) return;
  // only this application's own page: other applications on this server are left alone
  const page = event.request.mode === "navigate" && (url.pathname === BASE || url.pathname === `${BASE}index.html`);
  const wanted = page ? `${BASE}index.html` : event.request;
  // ignoreVary: these files are the same for every request, and a "Vary: Origin" header would
  // otherwise make the stored script miss when it is requested offline
  event.respondWith(caches.match(wanted, { cacheName: CACHE, ignoreVary: true }).then((hit) => hit ?? fetch(event.request)));
});
