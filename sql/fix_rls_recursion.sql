-- ================================================================
-- GuruIndo — Perbaikan Infinite Recursion di RLS
-- ================================================================
-- Masalah: beberapa policy saling mereferensikan tabel lain yang
-- punya RLS, termasuk satu policy guru_kelas yang menunjuk dirinya
-- sendiri. Ini bikin PostgreSQL muter tanpa henti → error 500.
--
-- Solusi: ganti semua pengecekan antar-tabel dengan fungsi
-- SECURITY DEFINER. Fungsi ini berjalan sebagai pemilik database
-- sehingga query di dalamnya MELEWATI RLS → rantai recursion putus.
--
-- Aman dijalankan: tabel masih kosong, tidak ada data yang hilang.
-- Jalankan di: Supabase → SQL Editor → New Query → paste → Run
-- ================================================================


-- ================================================================
-- BAGIAN 1: FUNGSI HELPER (SECURITY DEFINER — bypass RLS dgn aman)
-- ================================================================

-- Apakah user yang login adalah guru di kelas tertentu?
CREATE OR REPLACE FUNCTION is_guru_di_kelas(p_kelas_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM guru_kelas
    WHERE guru_id = auth.uid() AND kelas_id = p_kelas_id
  );
$$;

-- Apakah user yang login adalah ortu dari murid tertentu?
CREATE OR REPLACE FUNCTION is_ortu_dari_murid(p_murid_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM ortu_murid
    WHERE ortu_id = auth.uid() AND murid_id = p_murid_id
  );
$$;

-- Apakah user yang login adalah guru dari murid tertentu (via kelas)?
CREATE OR REPLACE FUNCTION is_guru_dari_murid(p_murid_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM murid m
    JOIN guru_kelas gk ON gk.kelas_id = m.kelas_id
    WHERE m.id = p_murid_id AND gk.guru_id = auth.uid()
  );
$$;

-- Apakah user yang login adalah guru di sekolah tertentu (via kelas)?
CREATE OR REPLACE FUNCTION is_guru_di_sekolah(p_sekolah_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM guru_kelas gk
    JOIN kelas k ON k.id = gk.kelas_id
    WHERE gk.guru_id = auth.uid() AND k.sekolah_id = p_sekolah_id
  );
$$;

-- Apakah user yang login adalah ortu di sekolah tertentu (via murid+kelas)?
CREATE OR REPLACE FUNCTION is_ortu_di_sekolah(p_sekolah_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM ortu_murid om
    JOIN murid m ON m.id = om.murid_id
    JOIN kelas k ON k.id = m.kelas_id
    WHERE om.ortu_id = auth.uid() AND k.sekolah_id = p_sekolah_id
  );
$$;

-- Apakah user yang login adalah ortu di kelas tertentu (via murid)?
CREATE OR REPLACE FUNCTION is_ortu_di_kelas(p_kelas_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM ortu_murid om
    JOIN murid m ON m.id = om.murid_id
    WHERE om.ortu_id = auth.uid() AND m.kelas_id = p_kelas_id
  );
$$;

-- Peran user yang login (bypass RLS profil)
CREATE OR REPLACE FUNCTION peran_saya()
RETURNS TEXT LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT peran FROM profil WHERE id = auth.uid();
$$;

-- Izin menjalankan fungsi helper untuk user yang login
GRANT EXECUTE ON FUNCTION is_guru_di_kelas(UUID)    TO authenticated;
GRANT EXECUTE ON FUNCTION is_ortu_dari_murid(UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION is_guru_dari_murid(UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION is_guru_di_sekolah(UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION is_ortu_di_sekolah(UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION is_ortu_di_kelas(UUID)    TO authenticated;
GRANT EXECUTE ON FUNCTION peran_saya()              TO authenticated;


-- ================================================================
-- BAGIAN 2: HAPUS SEMUA POLICY LAMA YANG BERMASALAH
-- ================================================================

-- profil
DROP POLICY IF EXISTS "profil_select_guru_lihat_ortu" ON profil;
DROP POLICY IF EXISTS "profil_select_ortu_lihat_guru" ON profil;

-- sekolah
DROP POLICY IF EXISTS "sekolah_select_guru_terdaftar" ON sekolah;
DROP POLICY IF EXISTS "sekolah_select_ortu"           ON sekolah;
DROP POLICY IF EXISTS "sekolah_insert_guru"           ON sekolah;

-- kelas
DROP POLICY IF EXISTS "kelas_select_guru" ON kelas;
DROP POLICY IF EXISTS "kelas_select_ortu" ON kelas;

-- murid
DROP POLICY IF EXISTS "murid_select_guru"             ON murid;
DROP POLICY IF EXISTS "murid_select_ortu_hanya_anaknya" ON murid;

-- guru_kelas (INI biang recursion — policy yang menunjuk dirinya sendiri)
DROP POLICY IF EXISTS "guru_kelas_select_sekelas" ON guru_kelas;

-- ortu_murid
DROP POLICY IF EXISTS "ortu_murid_select_guru" ON ortu_murid;


-- ================================================================
-- BAGIAN 3: BUAT ULANG POLICY — VERSI ANTI-RECURSION
-- ================================================================
-- Semua pengecekan antar-tabel sekarang lewat fungsi helper di atas.
-- Policy yang aman (cuma cek auth.uid() = kolom) TIDAK diubah.

-- ----------------------------------------------------------------
-- SEKOLAH
-- ----------------------------------------------------------------
CREATE POLICY "sekolah_select_guru_terdaftar"
  ON sekolah FOR SELECT
  USING (dibuat_oleh = auth.uid() OR is_guru_di_sekolah(sekolah.id));

CREATE POLICY "sekolah_select_ortu"
  ON sekolah FOR SELECT
  USING (is_ortu_di_sekolah(sekolah.id));

CREATE POLICY "sekolah_insert_guru"
  ON sekolah FOR INSERT
  WITH CHECK (peran_saya() = 'guru');

-- ----------------------------------------------------------------
-- KELAS
-- ----------------------------------------------------------------
CREATE POLICY "kelas_select_guru"
  ON kelas FOR SELECT
  USING (is_guru_di_kelas(kelas.id));

CREATE POLICY "kelas_select_ortu"
  ON kelas FOR SELECT
  USING (is_ortu_di_kelas(kelas.id));

-- ----------------------------------------------------------------
-- MURID
-- ----------------------------------------------------------------
CREATE POLICY "murid_select_guru"
  ON murid FOR SELECT
  USING (is_guru_di_kelas(murid.kelas_id));

-- KRITIS (UU PDP): ortu hanya lihat anaknya sendiri
CREATE POLICY "murid_select_ortu_hanya_anaknya"
  ON murid FOR SELECT
  USING (is_ortu_dari_murid(murid.id));

-- ----------------------------------------------------------------
-- ORTU_MURID
-- ----------------------------------------------------------------
CREATE POLICY "ortu_murid_select_guru"
  ON ortu_murid FOR SELECT
  USING (is_guru_dari_murid(ortu_murid.murid_id));

-- ----------------------------------------------------------------
-- PROFIL — visibilitas guru<->ortu
-- (dipakai Tahap 1 untuk menampilkan nama lawan bicara)
-- ----------------------------------------------------------------

-- Guru bisa lihat profil ortu yang punya anak di kelasnya
CREATE OR REPLACE FUNCTION ortu_ada_di_kelas_saya(p_ortu_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM ortu_murid om
    JOIN murid m      ON m.id        = om.murid_id
    JOIN guru_kelas gk ON gk.kelas_id = m.kelas_id
    WHERE om.ortu_id = p_ortu_id AND gk.guru_id = auth.uid()
  );
$$;

-- Ortu bisa lihat profil guru yang mengajar anaknya
CREATE OR REPLACE FUNCTION guru_ngajar_anak_saya(p_guru_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM guru_kelas gk
    JOIN murid m       ON m.kelas_id  = gk.kelas_id
    JOIN ortu_murid om ON om.murid_id = m.id
    WHERE gk.guru_id = p_guru_id AND om.ortu_id = auth.uid()
  );
$$;

GRANT EXECUTE ON FUNCTION ortu_ada_di_kelas_saya(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION guru_ngajar_anak_saya(UUID)  TO authenticated;

CREATE POLICY "profil_select_guru_lihat_ortu"
  ON profil FOR SELECT
  USING (ortu_ada_di_kelas_saya(profil.id));

CREATE POLICY "profil_select_ortu_lihat_guru"
  ON profil FOR SELECT
  USING (guru_ngajar_anak_saya(profil.id));


-- ================================================================
-- SELESAI!
-- Setelah ini, pembacaan profil tidak lagi memicu recursion.
-- Balik ke app, refresh keras (Ctrl+Shift+R), coba lagi.
-- ================================================================
