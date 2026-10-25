// Keeps the app itself available when the connection drops. Podcast audio and video always stream.
const CACHE = "pp-shell-v23";
const SHELL = ["./", "./index.html", "./manifest.webmanifest", "./favicon.ico?v=2", "./icons/n5pre2-180.png", "./icons/n5pre2-32.png", "./icons/n5pre2-192.png", "./icons/n5pre2-512.png"];
self.addEventListener("install", e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener("activate", e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim())); });
self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;
  // Network first so updates arrive; fall back to the saved copy offline.
  // Addresses with a query (such as the return from Dropbox sign-in) are never saved.
  const keep = !url.search;
  e.respondWith(fetch(e.request).then(r => { if (keep && r.ok) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); } return r; }).catch(() => caches.match(keep ? e.request : "./").then(m => m || caches.match("./"))));
});
