-- ================================================================
-- GuruIndo — Tahap 1b: KOMUNIKASI (Pengumuman + Catatan Personal)
-- ================================================================
-- Jalankan SETELAH setup.sql. File ini INCREMENTAL — hanya menambah
-- tabel/fungsi/aturan baru, tidak menyentuh data lama.
--
-- Cara pakai: Supabase -> SQL Editor -> New Query -> paste -> Run.
-- Aman dijalankan ulang (IF NOT EXISTS / OR REPLACE / DROP IF EXISTS).
--
-- Keputusan desain (sudah dikunci bareng):
--   1. SATU tabel `pesan` (jenis = 'pengumuman' | 'personal').
--   2. Status baca DITUNDA (Tahap 1c) — tidak dibuat sekarang.
--   3. Saklar "terima chat" GLOBAL per-guru -> kolom di `profil`.
--   4. Catatan personal DEFAULT boleh dibalas (boleh_balas = TRUE).
--   5. Pengumuman SEARAH — tidak bisa dibalas (dipaksa di level fungsi).
-- ================================================================


-- ================================================================
-- BAGIAN 1: KOLOM SAKLAR GLOBAL (di profil, untuk guru)
-- ================================================================
-- Saat FALSE: balasan ortu ke catatan personal DITAHAN (tidak terkirim),
-- ortu diberi tahu lewat pesan dari aplikasi. Pengumuman tidak terpengaruh.

ALTER TABLE profil
  ADD COLUMN IF NOT EXISTS terima_chat BOOLEAN NOT NULL DEFAULT TRUE;


-- ================================================================
-- BAGIAN 2: TABEL PESAN
-- ================================================================
-- Satu tabel untuk dua jenis:
--   * 'pengumuman' : kelas_id WAJIB, murid_id NULL, pengirim = guru.
--   * 'personal'   : murid_id WAJIB, kelas_id NULL, pengirim = guru/ortu.
--
-- balas_dari_id : jika pesan ini adalah balasan, menunjuk ke pesan induk.
-- boleh_balas   : hanya bermakna pada pesan personal dari GURU.
--                 Pengumuman selalu FALSE (dipaksa di fungsi kirim).

CREATE TABLE IF NOT EXISTS pesan (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  jenis         TEXT NOT NULL CHECK (jenis IN ('pengumuman', 'personal')),
  pengirim_id   UUID NOT NULL REFERENCES profil(id) ON DELETE CASCADE,
  kelas_id      UUID REFERENCES kelas(id) ON DELETE CASCADE,
  murid_id      UUID REFERENCES murid(id) ON DELETE CASCADE,
  isi           TEXT NOT NULL,
  boleh_balas   BOOLEAN NOT NULL DEFAULT FALSE,
  balas_dari_id UUID REFERENCES pesan(id) ON DELETE CASCADE,
  dibuat_pada   TIMESTAMPTZ DEFAULT NOW(),

  -- Jaga integritas: bentuk data harus sesuai jenisnya
  CONSTRAINT cek_bentuk_pesan CHECK (
    (jenis = 'pengumuman' AND kelas_id IS NOT NULL AND murid_id IS NULL)
    OR
    (jenis = 'personal'   AND murid_id IS NOT NULL AND kelas_id IS NULL)
  )
);

-- Index untuk query yang sering: per kelas (pengumuman) & per murid (personal)
CREATE INDEX IF NOT EXISTS idx_pesan_kelas ON pesan (kelas_id, dibuat_pada DESC);
CREATE INDEX IF NOT EXISTS idx_pesan_murid ON pesan (murid_id, dibuat_pada DESC);

ALTER TABLE pesan ENABLE ROW LEVEL SECURITY;


-- ================================================================
-- BAGIAN 3: FUNGSI HELPER (SECURITY DEFINER — anti recursion)
-- ================================================================
-- Mengikuti pola setup.sql Bagian 3. Semua cek "boleh lihat?" lewat
-- fungsi ini supaya policy tidak saling memanggil tanpa henti.

-- Boleh lihat pengumuman kelas X? (guru pengajar ATAU ortu murid di kelas itu)
CREATE OR REPLACE FUNCTION boleh_lihat_pengumuman(p_kelas_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT is_guru_di_kelas(p_kelas_id) OR is_ortu_di_kelas(p_kelas_id);
$$;

-- Boleh lihat catatan personal tentang murid X?
-- HANYA guru pengajar murid itu ATAU ortu (wali) murid itu. Ini inti UU PDP.
CREATE OR REPLACE FUNCTION boleh_lihat_personal(p_murid_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT is_guru_dari_murid(p_murid_id) OR is_ortu_dari_murid(p_murid_id);
$$;


-- ================================================================
-- BAGIAN 4: KEBIJAKAN RLS (pakai helper — tidak recursion)
-- ================================================================

-- ── SELECT: pengumuman terlihat oleh peserta kelas; personal hanya
--    oleh guru pengajar & wali murid ybs ──
DROP POLICY IF EXISTS "pesan_select_pengumuman" ON pesan;
CREATE POLICY "pesan_select_pengumuman" ON pesan FOR SELECT
  USING (jenis = 'pengumuman' AND boleh_lihat_pengumuman(pesan.kelas_id));

DROP POLICY IF EXISTS "pesan_select_personal" ON pesan;
CREATE POLICY "pesan_select_personal" ON pesan FOR SELECT
  USING (jenis = 'personal' AND boleh_lihat_personal(pesan.murid_id));

-- ── INSERT: hanya lewat fungsi RPC di Bawah. Kita TIDAK memberi
--    policy INSERT langsung agar semua aturan bisnis (searah,
--    saklar terima_chat, boleh_balas) terjaga di satu tempat. ──
-- (Tidak ada policy INSERT di sini — INSERT dilakukan oleh fungsi
--  SECURITY DEFINER yang melewati RLS.)


-- ================================================================
-- BAGIAN 5: FUNGSI AKSI (write) — semua aturan bisnis di sini
-- ================================================================

-- ── Kirim PENGUMUMAN (guru -> satu kelas) ──
-- Searah: boleh_balas dipaksa FALSE. Hanya guru pengajar kelas itu.
-- Menolak jika kelas belum punya murid (tidak ada yang akan membaca).
CREATE OR REPLACE FUNCTION kirim_pengumuman(p_kelas_id UUID, p_isi TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_id          UUID;
  v_jumlah_murid INT;
BEGIN
  IF NOT is_guru_di_kelas(p_kelas_id) THEN
    RAISE EXCEPTION 'Hanya guru di kelas ini yang bisa mengirim pengumuman';
  END IF;
  IF p_isi IS NULL OR trim(p_isi) = '' THEN
    RAISE EXCEPTION 'Isi pengumuman tidak boleh kosong';
  END IF;

  SELECT COUNT(*) INTO v_jumlah_murid FROM murid WHERE kelas_id = p_kelas_id;
  IF v_jumlah_murid = 0 THEN
    RAISE EXCEPTION 'Kelas ini belum punya murid. Tambahkan murid dulu sebelum mengirim pengumuman.';
  END IF;

  INSERT INTO pesan (jenis, pengirim_id, kelas_id, isi, boleh_balas)
  VALUES ('pengumuman', auth.uid(), p_kelas_id, trim(p_isi), FALSE)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('berhasil', TRUE, 'pesan_id', v_id);
END;
$$;

-- ── Kirim CATATAN PERSONAL (guru -> wali 1 murid) ──
-- p_boleh_balas mengatur apakah ortu boleh membalas catatan ini.
-- Hanya guru pengajar murid itu.
CREATE OR REPLACE FUNCTION kirim_catatan(
  p_murid_id    UUID,
  p_isi         TEXT,
  p_boleh_balas BOOLEAN DEFAULT TRUE
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_id UUID;
BEGIN
  IF NOT is_guru_dari_murid(p_murid_id) THEN
    RAISE EXCEPTION 'Hanya guru yang mengajar murid ini yang bisa mengirim catatan';
  END IF;
  IF p_isi IS NULL OR trim(p_isi) = '' THEN
    RAISE EXCEPTION 'Isi catatan tidak boleh kosong';
  END IF;

  INSERT INTO pesan (jenis, pengirim_id, murid_id, isi, boleh_balas)
  VALUES ('personal', auth.uid(), p_murid_id, trim(p_isi), COALESCE(p_boleh_balas, TRUE))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('berhasil', TRUE, 'pesan_id', v_id);
END;
$$;

-- ── Ortu BALAS catatan personal ──
-- Aturan bertingkat (gagal -> pesan jelas, tidak hilang diam-diam):
--   a. Pesan induk harus ada, jenis personal, & ortu memang wali murid itu.
--   b. Pesan induk harus boleh_balas = TRUE (guru mengizinkan).
--   c. Guru penerima harus terima_chat = TRUE (saklar global / "rem").
-- Jika (c) gagal -> kode khusus 'GURU_OFF' agar UI bisa tawarkan
--   "ingatkan saat guru aktif".
CREATE OR REPLACE FUNCTION balas_catatan(p_pesan_id UUID, p_isi TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_murid_id    UUID;
  v_jenis       TEXT;
  v_boleh_balas BOOLEAN;
  v_guru_id     UUID;
  v_guru_aktif  BOOLEAN;
  v_id          UUID;
BEGIN
  IF peran_saya() <> 'ortu' THEN
    RAISE EXCEPTION 'Hanya orang tua yang bisa membalas catatan';
  END IF;
  IF p_isi IS NULL OR trim(p_isi) = '' THEN
    RAISE EXCEPTION 'Balasan tidak boleh kosong';
  END IF;

  -- Ambil pesan induk
  SELECT murid_id, jenis, boleh_balas, pengirim_id
  INTO v_murid_id, v_jenis, v_boleh_balas, v_guru_id
  FROM pesan WHERE id = p_pesan_id;

  IF v_murid_id IS NULL OR v_jenis <> 'personal' THEN
    RAISE EXCEPTION 'Catatan tidak ditemukan';
  END IF;

  -- (a) Ortu harus wali murid ybs
  IF NOT is_ortu_dari_murid(v_murid_id) THEN
    RAISE EXCEPTION 'Kamu tidak punya akses ke catatan ini';
  END IF;

  -- (b) Guru mengizinkan balasan untuk catatan ini?
  IF NOT v_boleh_balas THEN
    RAISE EXCEPTION 'Catatan ini tidak dibuka untuk dibalas oleh guru';
  END IF;

  -- (c) Saklar global guru
  SELECT terima_chat INTO v_guru_aktif FROM profil WHERE id = v_guru_id;
  IF v_guru_aktif IS NOT TRUE THEN
    RETURN jsonb_build_object(
      'berhasil', FALSE, 'kode', 'GURU_OFF',
      'keterangan', 'Guru sedang menonaktifkan penerimaan pesan. Balasanmu belum terkirim.'
    );
  END IF;

  -- Lolos semua -> simpan balasan (ikut murid yang sama, boleh_balas FALSE)
  INSERT INTO pesan (jenis, pengirim_id, murid_id, isi, boleh_balas, balas_dari_id)
  VALUES ('personal', auth.uid(), v_murid_id, trim(p_isi), FALSE, p_pesan_id)
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('berhasil', TRUE, 'pesan_id', v_id);
END;
$$;

-- ── Guru ubah saklar global "terima_chat" ──
CREATE OR REPLACE FUNCTION set_terima_chat(p_aktif BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF peran_saya() <> 'guru' THEN
    RAISE EXCEPTION 'Hanya guru yang punya saklar ini';
  END IF;
  UPDATE profil SET terima_chat = COALESCE(p_aktif, TRUE) WHERE id = auth.uid();
  RETURN jsonb_build_object('berhasil', TRUE, 'terima_chat', COALESCE(p_aktif, TRUE));
END;
$$;

-- ── Daftar thread catatan personal untuk GURU (1 baris per murid yang
--    sudah pernah ada catatannya), beserta cuplikan terakhir ──
CREATE OR REPLACE FUNCTION daftar_catatan_guru()
RETURNS TABLE (
  murid_id     UUID,
  nama_murid   TEXT,
  nama_kelas   TEXT,
  isi_terakhir TEXT,
  waktu_terakhir TIMESTAMPTZ
)
LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT DISTINCT ON (p.murid_id)
    p.murid_id, m.nama, k.nama_kelas, p.isi, p.dibuat_pada
  FROM pesan p
  JOIN murid m ON m.id = p.murid_id
  JOIN kelas k ON k.id = m.kelas_id
  WHERE p.jenis = 'personal'
    AND is_guru_dari_murid(p.murid_id)
  ORDER BY p.murid_id, p.dibuat_pada DESC;
$$;

-- ── Daftar thread catatan personal untuk ORTU (1 baris per anak) ──
CREATE OR REPLACE FUNCTION daftar_catatan_ortu()
RETURNS TABLE (
  murid_id     UUID,
  nama_murid   TEXT,
  nama_kelas   TEXT,
  isi_terakhir TEXT,
  waktu_terakhir TIMESTAMPTZ
)
LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT DISTINCT ON (p.murid_id)
    p.murid_id, m.nama, k.nama_kelas, p.isi, p.dibuat_pada
  FROM pesan p
  JOIN murid m ON m.id = p.murid_id
  JOIN kelas k ON k.id = m.kelas_id
  WHERE p.jenis = 'personal'
    AND is_ortu_dari_murid(p.murid_id)
  ORDER BY p.murid_id, p.dibuat_pada DESC;
$$;


-- ================================================================
-- BAGIAN 6: HAK AKSES (GRANT) — wajib (auto-expose dimatikan)
-- ================================================================

GRANT SELECT ON public.pesan TO authenticated;
-- INSERT/UPDATE sengaja TIDAK di-grant: semua tulis lewat fungsi RPC.

GRANT EXECUTE ON FUNCTION boleh_lihat_pengumuman(UUID)        TO authenticated;
GRANT EXECUTE ON FUNCTION boleh_lihat_personal(UUID)          TO authenticated;
GRANT EXECUTE ON FUNCTION kirim_pengumuman(UUID, TEXT)        TO authenticated;
GRANT EXECUTE ON FUNCTION kirim_catatan(UUID, TEXT, BOOLEAN)  TO authenticated;
GRANT EXECUTE ON FUNCTION balas_catatan(UUID, TEXT)           TO authenticated;
GRANT EXECUTE ON FUNCTION set_terima_chat(BOOLEAN)            TO authenticated;
GRANT EXECUTE ON FUNCTION daftar_catatan_guru()              TO authenticated;
GRANT EXECUTE ON FUNCTION daftar_catatan_ortu()              TO authenticated;


-- ================================================================
-- SELESAI! Tahap 1b siap. Halaman: pengumuman, catatan-list,
-- catatan-thread (lihat folder pages/).
-- ================================================================
