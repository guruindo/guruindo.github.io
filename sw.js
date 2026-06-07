// ================================================================
// GuruIndo — Service Worker v4
// ================================================================
// Strategi:
//   * Dokumen HTML (navigasi)  -> NETWORK-FIRST + timeout.
//       online  : selalu ambil versi TERBARU dari network, lalu simpan
//                 salinannya ke cache (untuk fallback offline).
//       offline : ambil dari cache; kalau tak ada -> offline.html.
//     Ini mengatasi keluhan "user lihat halaman versi lama".
//   * Aset statis lokal (CSS/JS) -> STALE-WHILE-REVALIDATE.
//       sajikan cache (cepat) sambil memperbarui di belakang layar.
//   * Supabase & esm.sh -> TIDAK diintercept (biar realtime & ESM jalan).
//   * HANYA method GET yang ditangani (POST dll dibiarkan apa adanya).
// ================================================================

const CACHE = 'guruindo-v5'

// Basis scope: otomatis benar di root domain ATAU subfolder GitHub Pages.
const BASE = self.registration.scope

// Shell minimal yang di-precache saat install (jaring offline awal).
const SHELL = [
  '',
  'index.html',
  'manifest.json',
  'favicon.svg',
  'css/main.css',
  'css/components.css',
  'offline.html'
].map(p => new URL(p, BASE).toString())

const OFFLINE = new URL('offline.html', BASE).toString()

// Batas waktu network-first sebelum jatuh ke cache (sinyal jelek).
const TIMEOUT_MS = 3000

// ── Install: precache shell ──
self.addEventListener('install', e => {
  e.waitUntil(
    caches.open(CACHE)
      .then(c => c.addAll(SHELL))
      .then(() => self.skipWaiting())
  )
})

// ── Activate: buang cache versi lama ──
self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k !== CACHE).map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  )
})

// fetch dengan timeout; kalau lewat batas -> reject supaya jatuh ke cache.
function fetchDenganTimeout(request, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), ms)
    fetch(request).then(
      res => { clearTimeout(timer); resolve(res) },
      err => { clearTimeout(timer); reject(err) }
    )
  })
}

// Apakah request ini sebuah dokumen HTML (navigasi halaman)?
function isHTML(request) {
  if (request.mode === 'navigate') return true
  const accept = request.headers.get('accept') || ''
  return accept.includes('text/html')
}

// NETWORK-FIRST: untuk HTML. Online -> terbaru + simpan; offline -> cache/offline.html
async function networkFirst(request) {
  try {
    const res = await fetchDenganTimeout(request, TIMEOUT_MS)
    // Simpan salinan (clone) ke cache untuk fallback offline berikutnya.
    if (res && res.ok) {
      const salinan = res.clone()
      caches.open(CACHE).then(c => c.put(request, salinan)).catch(() => {})
    }
    return res
  } catch (_) {
    const cached = await caches.match(request)
    if (cached) return cached
    const offline = await caches.match(OFFLINE)
    if (offline) return offline
    return new Response('Offline', { status: 503, statusText: 'Offline' })
  }
}

// STALE-WHILE-REVALIDATE: untuk aset statis (CSS/JS). Cache dulu, perbarui di belakang.
async function staleWhileRevalidate(request) {
  const cached = await caches.match(request)
  const jaringan = fetch(request).then(res => {
    if (res && res.ok) {
      const salinan = res.clone()
      caches.open(CACHE).then(c => c.put(request, salinan)).catch(() => {})
    }
    return res
  }).catch(() => null)
  // Sajikan cache kalau ada; kalau belum, tunggu jaringan.
  return cached || (await jaringan) ||
    new Response('Offline', { status: 503, statusText: 'Offline' })
}

self.addEventListener('fetch', e => {
  const request = e.request

  // Hanya tangani GET. Selain itu (POST/PUT/dsb) biarkan lewat apa adanya.
  if (request.method !== 'GET') return

  // Jangan intercept Supabase (realtime) & esm.sh (ESM module).
  if (request.url.includes('supabase.co') ||
      request.url.includes('esm.sh')) return

  if (isHTML(request)) {
    e.respondWith(networkFirst(request))
  } else {
    e.respondWith(staleWhileRevalidate(request))
  }
})
