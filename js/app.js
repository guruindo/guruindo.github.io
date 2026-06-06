import { supabase } from './supabase.js'

// Daftarkan Service Worker (untuk PWA offline)
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('sw.js').catch(() => {})
  })
}

async function mulai() {
  // Tampilkan splash 1.5 detik biar terasa natural
  await new Promise(r => setTimeout(r, 1500))

  // Cek apakah user sudah login
  const { data: { session } } = await supabase.auth.getSession()

  if (!session) {
    const sudahOnboarding = localStorage.getItem('gi_onboarding')
    if (sudahOnboarding) {
      window.location.href = 'pages/masuk.html'
    } else {
      window.location.href = 'pages/onboarding.html'
    }
    return
  }

  // Sudah login — cek profil untuk tahu peran
  const { data: profil } = await supabase
    .from('profil')
    .select('peran')
    .eq('id', session.user.id)
    .maybeSingle()

  if (!profil) {
    window.location.href = 'pages/pilih-peran.html'
    return
  }

  if (profil.peran === 'guru') {
    window.location.href = 'pages/beranda-guru.html'
  } else {
    window.location.href = 'pages/beranda-ortu.html'
  }
}

mulai()
