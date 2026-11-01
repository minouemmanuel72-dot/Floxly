/* Floxly – sw.js : lancement hors ligne de l'interface.
   Ne met en cache QUE les fichiers de ce site (jamais Supabase, jamais les données).
   Pour publier une mise à jour, change VERSION. */
const VERSION = 'floxly-a1';
const CORE = ['./', 'index.html', 'config.js', 'api-supabase.js', 'manifest.webmanifest',
  'icons/favicon.svg', 'icons/icon-192.png', 'icons/icon-512.png', 'icons/icon-maskable-512.png', 'icons/apple-touch-icon.png'];
self.addEventListener('install', e => e.waitUntil(caches.open(VERSION).then(c => c.addAll(CORE)).then(() => self.skipWaiting())));
self.addEventListener('activate', e => e.waitUntil(
  caches.keys().then(ks => Promise.all(ks.filter(k => k !== VERSION).map(k => caches.delete(k)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET' || new URL(req.url).origin !== self.location.origin) return;
  if (req.mode === 'navigate') {
    e.respondWith(fetch(req).then(r => { const c = r.clone(); caches.open(VERSION).then(x => x.put('index.html', c)); return r; })
      .catch(() => caches.match('index.html')));
    return;
  }
  e.respondWith(fetch(req).then(r => { if (r && r.ok) { const c = r.clone(); caches.open(VERSION).then(x => x.put(req, c)); } return r; })
    .catch(() => caches.match(req)));
});
