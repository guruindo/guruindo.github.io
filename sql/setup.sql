-- ================================================================
-- GuruIndo — Setup Database LENGKAP v1.1
-- ================================================================
-- INI FILE SETUP KANONIK. Untuk pemasangan dari nol (sekolah baru),
-- cukup jalankan FILE INI SAJA. Sudah termasuk perbaikan recursion
-- dan fungsi Tahap 1a.
--
-- Cara pakai: Supabase → SQL Editor → New Query → paste → Run.
-- Aman dijalankan ulang (IF NOT EXISTS / OR REPLACE / DROP IF EXISTS).
--
-- Catatan untuk DB yang SUDAH ada datanya: file ini aman, tidak
-- menghapus baris data — hanya membuat/menyegarkan struktur & aturan.
-- ================================================================


-- ================================================================
-- BAGIAN 1: TABEL
-- ================================================================

CREATE TABLE IF NOT EXISTS profil (
  id              UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  nama            TEXT NOT NULL,
  peran           TEXT NOT NULL CHECK (peran IN ('guru', 'ortu')),
  foto_url        TEXT,
  dibuat_pada     TIMESTAMPTZ DEFAULT NOW(),
  diperbarui_pada TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sekolah (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  nama        TEXT NOT NULL,
  kota        TEXT,
  dibuat_oleh UUID REFERENCES profil(id) ON DELETE SET NULL,
  dibuat_pada TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS kelas (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  sekolah_id   UUID NOT NULL REFERENCES sekolah(id) ON DELETE CASCADE,
  nama_kelas   TEXT NOT NULL,
  kode_kelas   TEXT UNIQUE NOT NULL DEFAULT '',
  tahun_ajaran TEXT,
  dibuat_pada  TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS murid (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kelas_id    UUID NOT NULL REFERENCES kelas(id) ON DELETE CASCADE,
  nama        TEXT NOT NULL,
  kode_anak   TEXT UNIQUE NOT NULL DEFAULT '',
  dibuat_pada TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS guru_kelas (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  guru_id        UUID NOT NULL REFERENCES profil(id) ON DELETE CASCADE,
  kelas_id       UUID NOT NULL REFERENCES kelas(id) ON DELETE CASCADE,
  mapel          TEXT,
  is_wali        BOOLEAN DEFAULT FALSE,
  bergabung_pada TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(guru_id, kelas_id)
);

CREATE TABLE IF NOT EXISTS ortu_murid (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ortu_id        UUID NOT NULL REFERENCES profil(id) ON DELETE CASCADE,
  murid_id       UUID NOT NULL REFERENCES murid(id) ON DELETE CASCADE,
  hubungan       TEXT DEFAULT 'wali' CHECK (hubungan IN ('ayah', 'ibu', 'wali')),
  bergabung_pada TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(ortu_id, murid_id)
);


-- ================================================================
-- BAGIAN 2: AKTIFKAN RLS
-- ================================================================

ALTER TABLE profil     ENABLE ROW LEVEL SECURITY;
ALTER TABLE sekolah    ENABLE ROW LEVEL SECURITY;
ALTER TABLE kelas      ENABLE ROW LEVEL SECURITY;
ALTER TABLE murid      ENABLE ROW LEVEL SECURITY;
ALTER TABLE guru_kelas ENABLE ROW LEVEL SECURITY;
ALTER TABLE ortu_murid ENABLE ROW LEVEL SECURITY;


-- ================================================================
-- BAGIAN 3: FUNGSI HELPER (SECURITY DEFINER — anti recursion)
-- ================================================================
-- Semua pengecekan "apakah saya berhak?" lewat fungsi ini. Karena
-- SECURITY DEFINER, query di dalamnya MELEWATI RLS, jadi tidak ada
-- policy yang saling memanggil tanpa henti.

CREATE OR REPLACE FUNCTION peran_saya()
RETURNS TEXT LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT peran FROM profil WHERE id = auth.uid();
$$;

CREATE OR REPLACE FUNCTION is_guru_di_kelas(p_kelas_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM guru_kelas WHERE guru_id = auth.uid() AND kelas_id = p_kelas_id);
$$;

CREATE OR REPLACE FUNCTION is_ortu_dari_murid(p_murid_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (SELECT 1 FROM ortu_murid WHERE ortu_id = auth.uid() AND murid_id = p_murid_id);
$$;

CREATE OR REPLACE FUNCTION is_guru_dari_murid(p_murid_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM murid m JOIN guru_kelas gk ON gk.kelas_id = m.kelas_id
    WHERE m.id = p_murid_id AND gk.guru_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION is_guru_di_sekolah(p_sekolah_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM guru_kelas gk JOIN kelas k ON k.id = gk.kelas_id
    WHERE gk.guru_id = auth.uid() AND k.sekolah_id = p_sekolah_id
  );
$$;

CREATE OR REPLACE FUNCTION is_ortu_di_sekolah(p_sekolah_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM ortu_murid om JOIN murid m ON m.id = om.murid_id JOIN kelas k ON k.id = m.kelas_id
    WHERE om.ortu_id = auth.uid() AND k.sekolah_id = p_sekolah_id
  );
$$;

CREATE OR REPLACE FUNCTION is_ortu_di_kelas(p_kelas_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM ortu_murid om JOIN murid m ON m.id = om.murid_id
    WHERE om.ortu_id = auth.uid() AND m.kelas_id = p_kelas_id
  );
$$;

CREATE OR REPLACE FUNCTION ortu_ada_di_kelas_saya(p_ortu_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM ortu_murid om
    JOIN murid m       ON m.id        = om.murid_id
    JOIN guru_kelas gk ON gk.kelas_id = m.kelas_id
    WHERE om.ortu_id = p_ortu_id AND gk.guru_id = auth.uid()
  );
$$;

CREATE OR REPLACE FUNCTION guru_ngajar_anak_saya(p_guru_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT EXISTS (
    SELECT 1 FROM guru_kelas gk
    JOIN murid m       ON m.kelas_id  = gk.kelas_id
    JOIN ortu_murid om ON om.murid_id = m.id
    WHERE gk.guru_id = p_guru_id AND om.ortu_id = auth.uid()
  );
$$;


-- ================================================================
-- BAGIAN 4: KEBIJAKAN RLS (pakai helper di atas — tidak recursion)
-- ================================================================

-- ── PROFIL ──
DROP POLICY IF EXISTS "profil_select_own" ON profil;
CREATE POLICY "profil_select_own" ON profil FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "profil_select_guru_lihat_ortu" ON profil;
CREATE POLICY "profil_select_guru_lihat_ortu" ON profil FOR SELECT
  USING (ortu_ada_di_kelas_saya(profil.id));

DROP POLICY IF EXISTS "profil_select_ortu_lihat_guru" ON profil;
CREATE POLICY "profil_select_ortu_lihat_guru" ON profil FOR SELECT
  USING (guru_ngajar_anak_saya(profil.id));

DROP POLICY IF EXISTS "profil_insert_own" ON profil;
CREATE POLICY "profil_insert_own" ON profil FOR INSERT WITH CHECK (auth.uid() = id);

DROP POLICY IF EXISTS "profil_update_own" ON profil;
CREATE POLICY "profil_update_own" ON profil FOR UPDATE USING (auth.uid() = id);

-- ── SEKOLAH ──
DROP POLICY IF EXISTS "sekolah_select_guru_terdaftar" ON sekolah;
CREATE POLICY "sekolah_select_guru_terdaftar" ON sekolah FOR SELECT
  USING (dibuat_oleh = auth.uid() OR is_guru_di_sekolah(sekolah.id));

DROP POLICY IF EXISTS "sekolah_select_ortu" ON sekolah;
CREATE POLICY "sekolah_select_ortu" ON sekolah FOR SELECT
  USING (is_ortu_di_sekolah(sekolah.id));

DROP POLICY IF EXISTS "sekolah_insert_guru" ON sekolah;
CREATE POLICY "sekolah_insert_guru" ON sekolah FOR INSERT
  WITH CHECK (peran_saya() = 'guru');

DROP POLICY IF EXISTS "sekolah_update_pembuat" ON sekolah;
CREATE POLICY "sekolah_update_pembuat" ON sekolah FOR UPDATE
  USING (dibuat_oleh = auth.uid());

-- ── KELAS ──
DROP POLICY IF EXISTS "kelas_select_guru" ON kelas;
CREATE POLICY "kelas_select_guru" ON kelas FOR SELECT USING (is_guru_di_kelas(kelas.id));

DROP POLICY IF EXISTS "kelas_select_ortu" ON kelas;
CREATE POLICY "kelas_select_ortu" ON kelas FOR SELECT USING (is_ortu_di_kelas(kelas.id));

-- ── MURID ──
DROP POLICY IF EXISTS "murid_select_guru" ON murid;
CREATE POLICY "murid_select_guru" ON murid FOR SELECT USING (is_guru_di_kelas(murid.kelas_id));

DROP POLICY IF EXISTS "murid_select_ortu_hanya_anaknya" ON murid;
CREATE POLICY "murid_select_ortu_hanya_anaknya" ON murid FOR SELECT
  USING (is_ortu_dari_murid(murid.id));

-- ── GURU_KELAS ──
DROP POLICY IF EXISTS "guru_kelas_select_own" ON guru_kelas;
CREATE POLICY "guru_kelas_select_own" ON guru_kelas FOR SELECT USING (guru_id = auth.uid());

DROP POLICY IF EXISTS "guru_kelas_update_own" ON guru_kelas;
CREATE POLICY "guru_kelas_update_own" ON guru_kelas FOR UPDATE USING (guru_id = auth.uid());

-- ── ORTU_MURID ──
DROP POLICY IF EXISTS "ortu_murid_select_own" ON ortu_murid;
CREATE POLICY "ortu_murid_select_own" ON ortu_murid FOR SELECT USING (ortu_id = auth.uid());

DROP POLICY IF EXISTS "ortu_murid_select_guru" ON ortu_murid;
CREATE POLICY "ortu_murid_select_guru" ON ortu_murid FOR SELECT
  USING (is_guru_dari_murid(ortu_murid.murid_id));


-- ================================================================
-- BAGIAN 5: FUNGSI AKSI (write)
-- ================================================================

-- Generate kode unik XXXX-XXXX (tanpa karakter membingungkan)
CREATE OR REPLACE FUNCTION generate_kode_unik()
RETURNS TEXT LANGUAGE plpgsql AS $$
DECLARE
  karakter TEXT := 'ABCDEFGHJKMNPQRTUVWXYZ23456789';
  hasil    TEXT := '';
  i        INT;
BEGIN
  FOR i IN 1..8 LOOP
    hasil := hasil || substr(karakter, (floor(random() * length(karakter)) + 1)::INT, 1);
    IF i = 4 THEN hasil := hasil || '-'; END IF;
  END LOOP;
  RETURN hasil;
END;
$$;

-- Buat sekolah (jika perlu) + kelas, ATOMIK — anti "sekolah yatim"
CREATE OR REPLACE FUNCTION daftar_kelas_baru(
  p_nama_kelas    TEXT,
  p_nama_sekolah  TEXT DEFAULT NULL,
  p_sekolah_id    UUID DEFAULT NULL,
  p_tahun_ajaran  TEXT DEFAULT NULL,
  p_kota          TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_sekolah_id UUID;
  v_kelas_id   UUID;
  v_kode       TEXT;
  v_coba       INT := 0;
  v_nama_sek   TEXT;
BEGIN
  IF peran_saya() <> 'guru' THEN
    RAISE EXCEPTION 'Hanya guru yang bisa membuat kelas';
  END IF;
  IF p_nama_kelas IS NULL OR trim(p_nama_kelas) = '' THEN
    RAISE EXCEPTION 'Nama kelas tidak boleh kosong';
  END IF;

  IF p_sekolah_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM sekolah s
      WHERE s.id = p_sekolah_id
        AND (s.dibuat_oleh = auth.uid() OR is_guru_di_sekolah(s.id))
    ) THEN
      RAISE EXCEPTION 'Kamu tidak punya akses ke sekolah itu';
    END IF;
    v_sekolah_id := p_sekolah_id;
  ELSE
    IF p_nama_sekolah IS NULL OR trim(p_nama_sekolah) = '' THEN
      RAISE EXCEPTION 'Nama sekolah tidak boleh kosong';
    END IF;
    INSERT INTO sekolah (nama, kota, dibuat_oleh)
    VALUES (trim(p_nama_sekolah), NULLIF(trim(COALESCE(p_kota,'')),''), auth.uid())
    RETURNING id INTO v_sekolah_id;
  END IF;

  LOOP
    v_kode := generate_kode_unik();
    EXIT WHEN NOT EXISTS (SELECT 1 FROM kelas WHERE kode_kelas = v_kode);
    v_coba := v_coba + 1;
    IF v_coba > 20 THEN RAISE EXCEPTION 'Gagal membuat kode unik. Coba lagi.'; END IF;
  END LOOP;

  INSERT INTO kelas (sekolah_id, nama_kelas, kode_kelas, tahun_ajaran)
  VALUES (v_sekolah_id, trim(p_nama_kelas), v_kode, NULLIF(trim(COALESCE(p_tahun_ajaran,'')),''))
  RETURNING id INTO v_kelas_id;

  INSERT INTO guru_kelas (guru_id, kelas_id, is_wali)
  VALUES (auth.uid(), v_kelas_id, TRUE);

  SELECT nama INTO v_nama_sek FROM sekolah WHERE id = v_sekolah_id;

  RETURN jsonb_build_object(
    'kelas_id', v_kelas_id, 'sekolah_id', v_sekolah_id,
    'nama_kelas', trim(p_nama_kelas), 'nama_sekolah', v_nama_sek
  );
END;
$$;

-- List sekolah milik guru (untuk dropdown)
CREATE OR REPLACE FUNCTION daftar_sekolah_saya()
RETURNS TABLE (id UUID, nama TEXT, kota TEXT)
LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT DISTINCT s.id, s.nama, s.kota
  FROM sekolah s
  WHERE s.dibuat_oleh = auth.uid()
     OR EXISTS (
       SELECT 1 FROM guru_kelas gk JOIN kelas k ON k.id = gk.kelas_id
       WHERE gk.guru_id = auth.uid() AND k.sekolah_id = s.id
     );
$$;

-- Tambah murid → kembalikan kode_anak
CREATE OR REPLACE FUNCTION tambah_murid(p_kelas_id UUID, p_nama TEXT)
RETURNS TEXT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_kode TEXT; v_coba INT := 0;
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM guru_kelas
    WHERE guru_id = auth.uid() AND kelas_id = p_kelas_id AND is_wali = TRUE
  ) THEN
    RAISE EXCEPTION 'Hanya wali kelas yang bisa menambahkan murid';
  END IF;
  IF trim(p_nama) = '' THEN RAISE EXCEPTION 'Nama murid tidak boleh kosong'; END IF;

  LOOP
    v_kode := generate_kode_unik();
    EXIT WHEN NOT EXISTS (SELECT 1 FROM murid WHERE kode_anak = v_kode);
    v_coba := v_coba + 1;
    IF v_coba > 20 THEN RAISE EXCEPTION 'Gagal membuat kode unik. Coba lagi.'; END IF;
  END LOOP;

  INSERT INTO murid (kelas_id, nama, kode_anak)
  VALUES (p_kelas_id, trim(p_nama), v_kode);
  RETURN v_kode;
END;
$$;

-- Ortu klaim anak via kode
CREATE OR REPLACE FUNCTION klaim_anak(p_kode_anak TEXT)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_murid_id UUID; v_nama TEXT; v_kelas TEXT; v_sekolah TEXT;
BEGIN
  IF peran_saya() <> 'ortu' THEN
    RAISE EXCEPTION 'Hanya orang tua yang bisa menghubungkan anak';
  END IF;
  IF trim(p_kode_anak) = '' THEN RAISE EXCEPTION 'Kode tidak boleh kosong'; END IF;

  SELECT m.id, m.nama, k.nama_kelas, s.nama
  INTO v_murid_id, v_nama, v_kelas, v_sekolah
  FROM murid m JOIN kelas k ON k.id = m.kelas_id JOIN sekolah s ON s.id = k.sekolah_id
  WHERE m.kode_anak = upper(trim(p_kode_anak));

  IF v_murid_id IS NULL THEN
    RAISE EXCEPTION 'Kode tidak ditemukan. Pastikan kode sudah benar ya';
  END IF;
  IF EXISTS (SELECT 1 FROM ortu_murid WHERE ortu_id = auth.uid() AND murid_id = v_murid_id) THEN
    RAISE EXCEPTION 'Kamu sudah terhubung dengan anak ini sebelumnya';
  END IF;

  INSERT INTO ortu_murid (ortu_id, murid_id, hubungan)
  VALUES (auth.uid(), v_murid_id, 'wali');

  RETURN jsonb_build_object(
    'berhasil', TRUE, 'nama_anak', v_nama, 'kelas', v_kelas, 'sekolah', v_sekolah
  );
END;
$$;

-- Trigger perbarui timestamp
CREATE OR REPLACE FUNCTION update_diperbarui_pada()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN NEW.diperbarui_pada = NOW(); RETURN NEW; END;
$$;
DROP TRIGGER IF EXISTS tr_profil_diperbarui ON profil;
CREATE TRIGGER tr_profil_diperbarui BEFORE UPDATE ON profil
  FOR EACH ROW EXECUTE FUNCTION update_diperbarui_pada();


-- ================================================================
-- BAGIAN 6: HAK AKSES (GRANT) — wajib karena auto-expose dimatikan
-- ================================================================

GRANT SELECT, INSERT, UPDATE, DELETE ON public.profil      TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.sekolah     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.kelas       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.murid       TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.guru_kelas  TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.ortu_murid  TO authenticated;

GRANT EXECUTE ON FUNCTION peran_saya()                 TO authenticated;
GRANT EXECUTE ON FUNCTION is_guru_di_kelas(UUID)       TO authenticated;
GRANT EXECUTE ON FUNCTION is_ortu_dari_murid(UUID)     TO authenticated;
GRANT EXECUTE ON FUNCTION is_guru_dari_murid(UUID)     TO authenticated;
GRANT EXECUTE ON FUNCTION is_guru_di_sekolah(UUID)     TO authenticated;
GRANT EXECUTE ON FUNCTION is_ortu_di_sekolah(UUID)     TO authenticated;
GRANT EXECUTE ON FUNCTION is_ortu_di_kelas(UUID)       TO authenticated;
GRANT EXECUTE ON FUNCTION ortu_ada_di_kelas_saya(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION guru_ngajar_anak_saya(UUID)  TO authenticated;
GRANT EXECUTE ON FUNCTION generate_kode_unik()         TO authenticated;
GRANT EXECUTE ON FUNCTION daftar_kelas_baru(TEXT, TEXT, UUID, TEXT, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION daftar_sekolah_saya()        TO authenticated;
GRANT EXECUTE ON FUNCTION tambah_murid(UUID, TEXT)     TO authenticated;
GRANT EXECUTE ON FUNCTION klaim_anak(TEXT)             TO authenticated;


-- ================================================================
-- SELESAI! Database GuruIndo siap dipakai (fondasi + Tahap 1a).
-- ================================================================
