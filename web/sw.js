// Service Worker: cachea el app-shell (versionado) para que el SPA cargue aunque el hosting no responda.
// Las llamadas a las APIs (otro origen) NO se interceptan: el failover lo decide app.js.
const VERSION = 'v3';
const CACHE = `aa-shell-${VERSION}`;
const SHELL = ['./', './index.html', './app.js', './styles.css', './manifest.webmanifest', './icon.svg', './visor.html', './visor.js'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  if (url.origin !== self.location.origin || e.request.method !== 'GET') return;
  // config.json: red primero (puede cambiar al redesplegar), caché como respaldo
  if (url.pathname.endsWith('/config.json')) {
    e.respondWith(
      fetch(e.request).then((r) => { const copy = r.clone(); caches.open(CACHE).then((c) => c.put(e.request, copy)); return r; })
        .catch(() => caches.match(e.request))
    );
    return;
  }
  // app-shell: caché primero, y se revalida en segundo plano contra el servidor (sin pasar por la caché HTTP del navegador)
  e.respondWith(
    caches.match(e.request, { ignoreSearch: true }).then((hit) => {
      const net = fetch(e.request, { cache: 'no-cache' }).then((r) => {
        if (r && r.ok) caches.open(CACHE).then((c) => c.put(e.request, r.clone()));
        return r;
      }).catch(() => hit);
      return hit || net;
    })
  );
});
