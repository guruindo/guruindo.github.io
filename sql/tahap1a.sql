-- ================================================================
-- GuruIndo — Tahap 1a: Fungsi Daftar Kelas & Murid
-- ================================================================
-- Jalankan di: Supabase → SQL Editor → New Query → paste → Run
-- Aman dijalankan ulang (pakai OR REPLACE).
-- ================================================================


-- ----------------------------------------------------------------
-- 1. daftar_kelas_baru — buat sekolah (jika perlu) + kelas, ATOMIK
-- ----------------------------------------------------------------
-- Penangkal Murphy #1: kalau salah satu langkah gagal, SEMUANYA
-- dibatalkan (rollback otomatis dalam satu fungsi). Tidak akan ada
-- "sekolah yatim" tanpa kelas.
--
-- Dua mode:
--   - Kalau p_sekolah_id NULL  -> buat sekolah baru dari p_nama_sekolah
--   - Kalau p_sekolah_id diisi -> pakai sekolah yang sudah ada
--
-- Mengembalikan: data kelas yang baru dibuat (JSON)
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION daftar_kelas_baru(
  p_nama_kelas    TEXT,
  p_nama_sekolah  TEXT DEFAULT NULL,
  p_sekolah_id    UUID DEFAULT NULL,
  p_tahun_ajaran  TEXT DEFAULT NULL,
  p_kota          TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_sekolah_id UUID;
  v_kelas_id   UUID;
  v_kode       TEXT;
  v_coba       INT := 0;
  v_nama_sek   TEXT;
BEGIN
  -- Validasi: hanya guru
  IF peran_saya() <> 'guru' THEN
    RAISE EXCEPTION 'Hanya guru yang bisa membuat kelas';
  END IF;

  -- Validasi input
  IF p_nama_kelas IS NULL OR trim(p_nama_kelas) = '' THEN
    RAISE EXCEPTION 'Nama kelas tidak boleh kosong';
  END IF;

  -- Tentukan sekolah: pakai yang ada, atau buat baru
  IF p_sekolah_id IS NOT NULL THEN
    -- Pastikan guru memang berhak di sekolah ini (sudah punya kelas di sana)
    --   atau dia pembuatnya
    IF NOT EXISTS (
      SELECT 1 FROM sekolah s
      WHERE s.id = p_sekolah_id
        AND (s.dibuat_oleh = auth.uid() OR is_guru_di_sekolah(s.id))
    ) THEN
      RAISE EXCEPTION 'Kamu tidak punya akses ke sekolah itu';
    END IF;
    v_sekolah_id := p_sekolah_id;
  ELSE
    -- Buat sekolah baru
    IF p_nama_sekolah IS NULL OR trim(p_nama_sekolah) = '' THEN
      RAISE EXCEPTION 'Nama sekolah tidak boleh kosong';
    END IF;
    INSERT INTO sekolah (nama, kota, dibuat_oleh)
    VALUES (trim(p_nama_sekolah), NULLIF(trim(COALESCE(p_kota,'')), ''), auth.uid())
    RETURNING id INTO v_sekolah_id;
  END IF;

  -- Generate kode_kelas unik
  LOOP
    v_kode := generate_kode_unik();
    EXIT WHEN NOT EXISTS (SELECT 1 FROM kelas WHERE kode_kelas = v_kode);
    v_coba := v_coba + 1;
    IF v_coba > 20 THEN
      RAISE EXCEPTION 'Gagal membuat kode unik. Coba lagi.';
    END IF;
  END LOOP;

  -- Buat kelas
  INSERT INTO kelas (sekolah_id, nama_kelas, kode_kelas, tahun_ajaran)
  VALUES (
    v_sekolah_id,
    trim(p_nama_kelas),
    v_kode,
    NULLIF(trim(COALESCE(p_tahun_ajaran,'')), '')
  )
  RETURNING id INTO v_kelas_id;

  -- Daftarkan guru sebagai wali kelas
  INSERT INTO guru_kelas (guru_id, kelas_id, is_wali)
  VALUES (auth.uid(), v_kelas_id, TRUE);

  -- Ambil nama sekolah untuk dikembalikan
  SELECT nama INTO v_nama_sek FROM sekolah WHERE id = v_sekolah_id;

  RETURN jsonb_build_object(
    'kelas_id',    v_kelas_id,
    'sekolah_id',  v_sekolah_id,
    'nama_kelas',  trim(p_nama_kelas),
    'nama_sekolah', v_nama_sek
  );
END;
$$;


-- ----------------------------------------------------------------
-- 2. daftar_sekolah_saya — list sekolah yang guru ini sudah punya
--    (untuk dropdown "pilih sekolah yang sudah ada")
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION daftar_sekolah_saya()
RETURNS TABLE (id UUID, nama TEXT, kota TEXT)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT DISTINCT s.id, s.nama, s.kota
  FROM sekolah s
  WHERE s.dibuat_oleh = auth.uid()
     OR EXISTS (
       SELECT 1 FROM guru_kelas gk
       JOIN kelas k ON k.id = gk.kelas_id
       WHERE gk.guru_id = auth.uid() AND k.sekolah_id = s.id
     );
$$;


-- Izin eksekusi
GRANT EXECUTE ON FUNCTION daftar_kelas_baru(TEXT, TEXT, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION daftar_sekolah_saya()                          TO authenticated;


-- ================================================================
-- SELESAI! Lanjut: deploy halaman daftar-kelas & kelas.
-- ================================================================
