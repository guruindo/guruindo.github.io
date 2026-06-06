import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

// ================================================================
// GANTI DUA BARIS DI BAWAH INI
// Ambil dari: Supabase dashboard → Settings → API Keys
// ================================================================
const SUPABASE_URL = 'https://izcaycwgaitalxhwxqkr.supabase.co'
const SUPABASE_KEY = 'sb_publishable_HuPvZEM2r9DcrMrwkmWJWA_HhkYsoyu'
// ================================================================

if (SUPABASE_URL === 'GANTI_DENGAN_URL_SUPABASEMU' || SUPABASE_KEY === 'GANTI_DENGAN_PUBLISHABLE_KEY') {
  console.warn('⚠️ Buka js/supabase.js dan isi URL dan Key dari Supabase!')
}

export const supabase = createClient(SUPABASE_URL, SUPABASE_KEY)
