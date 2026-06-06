// Versi dinaikkan -> memaksa browser mengganti SW lama (mis. sisa dari Netlify)
const CACHE = 'guruindo-v2'

// Basis scope: otomatis benar di root domain ATAU subfolder GitHub Pages.
// Contoh: di Netlify -> "https://situs/" ; di GH Pages -> "https://user.github.io/guruindo/"
const BASE = self.registration.scope

// Daftar shell, RELATIF terhadap BASE (bukan '/...')
const SHELL = [
  '',
  'index.html',
  'manifest.json',
  'css/main.css',
  'css/components.css',
  'offline.html'
].map(p => new URL(p, BASE).toString())

const OFFLINE = new URL('offline.html', BASE).toString()

self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(SHELL))
      .then(() => self.skipWaiting())
  )
})

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  )
})

self.addEventListener('fetch', e => {
  // Jangan intercept request ke Supabase (agar realtime tetap jalan) & esm.sh
  if (e.request.url.includes('supabase.co') ||
      e.request.url.includes('esm.sh')) return

  e.respondWith(
    caches.match(e.request).then(cached => {
      if (cached) return cached
      return fetch(e.request).catch(() => caches.match(OFFLINE))
    })
  )
})
