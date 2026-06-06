-- ================================================================
-- GuruIndo — Tahap 2: ABSENSI (model "Exception-Only")
-- ================================================================
-- Jalankan SETELAH setup.sql DAN tahap1b.sql. File ini INCREMENTAL —
-- hanya menambah tabel/fungsi/aturan baru, tidak menyentuh data lama.
--
-- Cara pakai: Supabase -> SQL Editor -> New Query -> paste -> Run.
-- Aman dijalankan ulang (IF NOT EXISTS / OR REPLACE / DROP IF EXISTS).
--
-- MODEL INTI (sudah dikunci bareng):
--   * Default tiap murid = HADIR. Guru tidak input apa pun untuk yang hadir.
--   * Guru hanya menandai yang IZIN / SAKIT / ALPA.
--   * Guru menekan "Tutup Absensi Hari Ini" -> saat itulah sisa murid
--     resmi tercatat HADIR & notif (Fase 2) dikirim ke ortu murid absen.
--   * Belum ditutup = keadaan 'belum' (JUJUR: bukan "hadir semua",
--     bukan dianggap guru lupa).
--   * Guru boleh RALAT kapan saja (ubah status / buka kembali).
--   * MINGGU = auto-skip di level fungsi (tidak bisa absen).
--     Hari libur lain -> guru menandai 'libur' (set_hari_libur).
--   * Tanggal SELALU dari server (CURRENT_DATE), bukan tanggal browser.
-- ================================================================


-- ================================================================
-- BAGIAN 1: TABEL
-- ================================================================

-- (A) Status kehadiran per MURID per TANGGAL.
--     Hanya baris untuk murid yang TIDAK hadir yang biasanya ada di sini
--     SEBELUM ditutup. Saat "Tutup", sisa murid yang belum punya baris
--     akan diisi 'hadir' secara eksplisit (lihat fungsi tutup_absensi).
--     kelas_id disimpan sebagai SNAPSHOT (riwayat tak berubah walau murid
--     pindah kelas nanti).
CREATE TABLE IF NOT EXISTS absensi (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  murid_id        UUID NOT NULL REFERENCES murid(id) ON DELETE CASCADE,
  kelas_id        UUID NOT NULL REFERENCES kelas(id) ON DELETE CASCADE,
  tanggal         DATE NOT NULL,
  status          TEXT NOT NULL CHECK (status IN ('hadir', 'izin', 'sakit', 'alpa')),
  catatan         TEXT,
  dicatat_oleh    UUID REFERENCES profil(id) ON DELETE SET NULL,
  dibuat_pada     TIMESTAMPTZ DEFAULT NOW(),
  diperbarui_pada TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (murid_id, tanggal)   -- anti dobel & anti klik-2x / 2-tab
);

CREATE INDEX IF NOT EXISTS idx_absensi_kelas_tgl ON absensi (kelas_id, tanggal);
CREATE INDEX IF NOT EXISTS idx_absensi_murid_tgl ON absensi (murid_id, tanggal DESC);

-- (B) Keadaan absensi per KELAS per TANGGAL.
--     'belum'    : guru belum menutup (status hari ini belum final)
--     'ditutup'  : guru sudah menutup -> sisa murid resmi hadir
--     'libur'    : hari ini diliburkan -> tidak ada absensi
CREATE TABLE IF NOT EXISTS absensi_hari (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kelas_id     UUID NOT NULL REFERENCES kelas(id) ON DELETE CASCADE,
  tanggal      DATE NOT NULL,
  keadaan      TEXT NOT NULL DEFAULT 'belum'
                 CHECK (keadaan IN ('belum', 'ditutup', 'libur')),
  diubah_oleh  UUID REFERENCES profil(id) ON DELETE SET NULL,
  diubah_pada  TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (kelas_id, tanggal)
);

CREATE INDEX IF NOT EXISTS idx_absensi_hari_kelas ON absensi_hari (kelas_id, tanggal DESC);


-- ================================================================
-- BAGIAN 2: AKTIFKAN RLS
-- ================================================================

ALTER TABLE absensi      ENABLE ROW LEVEL SECURITY;
ALTER TABLE absensi_hari ENABLE ROW LEVEL SECURITY;


-- ================================================================
-- BAGIAN 3: FUNGSI HELPER (SECURITY DEFINER — anti recursion)
-- ================================================================
-- Memakai helper yang SUDAH ADA di setup.sql: is_guru_di_kelas(),
-- is_ortu_dari_murid(). Tidak ada policy yang mereferensikan tabel lain
-- secara langsung -> aman dari infinite recursion (pelajaran pahit 1).

-- Boleh lihat absensi 1 murid? (guru pengajar murid itu ATAU wali murid itu)
CREATE OR REPLACE FUNCTION boleh_lihat_absensi_murid(p_murid_id UUID)
RETURNS BOOLEAN LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT is_guru_dari_murid(p_murid_id) OR is_ortu_dari_murid(p_murid_id);
$$;


-- ================================================================
-- BAGIAN 4: KEBIJAKAN RLS (pakai helper — tidak recursion)
-- ================================================================
-- SELECT saja yang diberi policy. INSERT/UPDATE/DELETE sengaja TIDAK
-- di-grant: semua tulis lewat fungsi RPC SECURITY DEFINER (pola 1b),
-- supaya seluruh aturan bisnis (default hadir, tutup, libur, anti-Minggu)
-- terjaga di satu tempat.

-- ── absensi: guru kelas lihat semua muridnya; ortu lihat anaknya saja ──
DROP POLICY IF EXISTS "absensi_select_guru" ON absensi;
CREATE POLICY "absensi_select_guru" ON absensi FOR SELECT
  USING (is_guru_di_kelas(absensi.kelas_id));

DROP POLICY IF EXISTS "absensi_select_ortu" ON absensi;
CREATE POLICY "absensi_select_ortu" ON absensi FOR SELECT
  USING (is_ortu_dari_murid(absensi.murid_id));

-- ── absensi_hari: terlihat oleh guru kelas & ortu murid di kelas itu ──
DROP POLICY IF EXISTS "absensi_hari_select_guru" ON absensi_hari;
CREATE POLICY "absensi_hari_select_guru" ON absensi_hari FOR SELECT
  USING (is_guru_di_kelas(absensi_hari.kelas_id));

DROP POLICY IF EXISTS "absensi_hari_select_ortu" ON absensi_hari;
CREATE POLICY "absensi_hari_select_ortu" ON absensi_hari FOR SELECT
  USING (is_ortu_di_kelas(absensi_hari.kelas_id));


-- ================================================================
-- BAGIAN 5: FUNGSI AKSI (write) — semua aturan bisnis di sini
-- ================================================================

-- Penjaga umum: pastikan tanggal absen valid untuk dicatat.
-- Menolak hari MINGGU (EXTRACT(DOW)=0) dan hari yang ditandai 'libur'.
-- Dipakai internal oleh fungsi tulis di bawah.
CREATE OR REPLACE FUNCTION _absensi_boleh_dicatat(p_kelas_id UUID, p_tanggal DATE)
RETURNS BOOLEAN LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_keadaan TEXT;
BEGIN
  -- Minggu auto-skip (0 = Minggu pada PostgreSQL DOW)
  IF EXTRACT(DOW FROM p_tanggal) = 0 THEN
    RETURN FALSE;
  END IF;
  -- Hari yang ditandai libur
  SELECT keadaan INTO v_keadaan
  FROM absensi_hari WHERE kelas_id = p_kelas_id AND tanggal = p_tanggal;
  IF v_keadaan = 'libur' THEN
    RETURN FALSE;
  END IF;
  RETURN TRUE;
END;
$$;

-- ── Tandai status SATU murid pada HARI INI (server-side date) ──
-- Dipakai guru untuk menandai izin/sakit/alpa, atau meralat ke 'hadir'.
-- UPSERT idempoten: klik berkali-kali / 2 tab tetap aman.
-- Sekaligus memastikan baris absensi_hari kelas ini ada (keadaan 'belum'
-- jika belum pernah dibuat) supaya hari ini "tercatat sedang dikerjakan".
CREATE OR REPLACE FUNCTION set_absensi_murid(
  p_murid_id UUID,
  p_status   TEXT,
  p_catatan  TEXT DEFAULT NULL
)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_kelas_id UUID;
  v_tanggal  DATE := CURRENT_DATE;
BEGIN
  IF p_status NOT IN ('hadir', 'izin', 'sakit', 'alpa') THEN
    RAISE EXCEPTION 'Status tidak dikenal';
  END IF;
  IF NOT is_guru_dari_murid(p_murid_id) THEN
    RAISE EXCEPTION 'Hanya guru yang mengajar murid ini yang bisa mengabsen';
  END IF;

  -- Ambil kelas murid (snapshot kelas saat ini)
  SELECT kelas_id INTO v_kelas_id FROM murid WHERE id = p_murid_id;
  IF v_kelas_id IS NULL THEN
    RAISE EXCEPTION 'Murid tidak ditemukan';
  END IF;

  IF NOT _absensi_boleh_dicatat(v_kelas_id, v_tanggal) THEN
    RAISE EXCEPTION 'Hari ini tidak bisa diabsen (hari Minggu atau ditandai libur)';
  END IF;

  -- Pastikan baris hari ada & berkeadaan minimal 'belum'
  INSERT INTO absensi_hari (kelas_id, tanggal, keadaan, diubah_oleh)
  VALUES (v_kelas_id, v_tanggal, 'belum', auth.uid())
  ON CONFLICT (kelas_id, tanggal) DO NOTHING;

  -- UPSERT status murid
  INSERT INTO absensi (murid_id, kelas_id, tanggal, status, catatan, dicatat_oleh)
  VALUES (p_murid_id, v_kelas_id, v_tanggal, p_status, NULLIF(trim(COALESCE(p_catatan,'')),''), auth.uid())
  ON CONFLICT (murid_id, tanggal)
  DO UPDATE SET
    status          = EXCLUDED.status,
    catatan         = EXCLUDED.catatan,
    kelas_id        = EXCLUDED.kelas_id,
    dicatat_oleh    = EXCLUDED.dicatat_oleh,
    diperbarui_pada = NOW();

  RETURN jsonb_build_object('berhasil', TRUE, 'status', p_status);
END;
$$;

-- ── TUTUP absensi hari ini untuk 1 kelas ──
-- Atomik: dalam SATU transaksi, semua murid kelas yang BELUM punya baris
-- hari ini diisi 'hadir', lalu keadaan -> 'ditutup'. Gagal di tengah =
-- tidak ada yang berubah (Murphy: koneksi putus saat tutup).
-- Idempoten: menutup ulang aman (murid yang sudah ada tidak ditimpa).
CREATE OR REPLACE FUNCTION tutup_absensi(p_kelas_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tanggal     DATE := CURRENT_DATE;
  v_jumlah      INT;
  v_tidak_hadir INT;
BEGIN
  IF NOT is_guru_di_kelas(p_kelas_id) THEN
    RAISE EXCEPTION 'Hanya guru di kelas ini yang bisa menutup absensi';
  END IF;
  IF NOT _absensi_boleh_dicatat(p_kelas_id, v_tanggal) THEN
    RAISE EXCEPTION 'Hari ini tidak bisa diabsen (hari Minggu atau ditandai libur)';
  END IF;

  SELECT COUNT(*) INTO v_jumlah FROM murid WHERE kelas_id = p_kelas_id;
  IF v_jumlah = 0 THEN
    RAISE EXCEPTION 'Kelas ini belum punya murid';
  END IF;

  -- Isi 'hadir' untuk murid yang belum punya baris hari ini
  INSERT INTO absensi (murid_id, kelas_id, tanggal, status, dicatat_oleh)
  SELECT m.id, m.kelas_id, v_tanggal, 'hadir', auth.uid()
  FROM murid m
  WHERE m.kelas_id = p_kelas_id
    AND NOT EXISTS (
      SELECT 1 FROM absensi a WHERE a.murid_id = m.id AND a.tanggal = v_tanggal
    );

  -- Tandai hari ini DITUTUP
  INSERT INTO absensi_hari (kelas_id, tanggal, keadaan, diubah_oleh, diubah_pada)
  VALUES (p_kelas_id, v_tanggal, 'ditutup', auth.uid(), NOW())
  ON CONFLICT (kelas_id, tanggal)
  DO UPDATE SET keadaan = 'ditutup', diubah_oleh = auth.uid(), diubah_pada = NOW();

  SELECT COUNT(*) INTO v_tidak_hadir
  FROM absensi WHERE kelas_id = p_kelas_id AND tanggal = v_tanggal AND status <> 'hadir';

  RETURN jsonb_build_object(
    'berhasil', TRUE, 'jumlah_murid', v_jumlah, 'tidak_hadir', v_tidak_hadir
  );
END;
$$;

-- ── BUKA kembali absensi hari ini (ralat setelah tutup) ──
-- Sesuai keputusan: guru boleh ralat kapan saja. Mengembalikan keadaan
-- ke 'belum'. Baris status murid TIDAK dihapus (guru tinggal mengubah
-- yang perlu, lalu menutup lagi).
CREATE OR REPLACE FUNCTION buka_absensi(p_kelas_id UUID)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_tanggal DATE := CURRENT_DATE;
BEGIN
  IF NOT is_guru_di_kelas(p_kelas_id) THEN
    RAISE EXCEPTION 'Hanya guru di kelas ini yang bisa membuka absensi';
  END IF;
  UPDATE absensi_hari
  SET keadaan = 'belum', diubah_oleh = auth.uid(), diubah_pada = NOW()
  WHERE kelas_id = p_kelas_id AND tanggal = v_tanggal;
  RETURN jsonb_build_object('berhasil', TRUE);
END;
$$;

-- ── Tandai / batalkan HARI LIBUR untuk 1 kelas pada hari ini ──
-- p_libur = TRUE  -> keadaan 'libur' (tidak ada absensi hari ini)
-- p_libur = FALSE -> kembali 'belum'
-- Menolak menandai libur jika sudah ada murid yang terlanjur diabsen
-- hari ini (cegah data nyangkut tak konsisten).
CREATE OR REPLACE FUNCTION set_hari_libur(p_kelas_id UUID, p_libur BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_tanggal DATE := CURRENT_DATE;
  v_ada     INT;
BEGIN
  IF NOT is_guru_di_kelas(p_kelas_id) THEN
    RAISE EXCEPTION 'Hanya guru di kelas ini yang bisa mengatur hari libur';
  END IF;

  IF p_libur THEN
    SELECT COUNT(*) INTO v_ada
    FROM absensi WHERE kelas_id = p_kelas_id AND tanggal = v_tanggal;
    IF v_ada > 0 THEN
      RAISE EXCEPTION 'Sudah ada murid yang diabsen hari ini. Hapus/ralat dulu sebelum menandai libur.';
    END IF;
    INSERT INTO absensi_hari (kelas_id, tanggal, keadaan, diubah_oleh, diubah_pada)
    VALUES (p_kelas_id, v_tanggal, 'libur', auth.uid(), NOW())
    ON CONFLICT (kelas_id, tanggal)
    DO UPDATE SET keadaan = 'libur', diubah_oleh = auth.uid(), diubah_pada = NOW();
  ELSE
    UPDATE absensi_hari
    SET keadaan = 'belum', diubah_oleh = auth.uid(), diubah_pada = NOW()
    WHERE kelas_id = p_kelas_id AND tanggal = v_tanggal;
  END IF;

  RETURN jsonb_build_object('berhasil', TRUE, 'libur', p_libur);
END;
$$;

-- ── REKAP absensi 1 kelas pada SATU tanggal (untuk layar guru) ──
-- Mengembalikan SETIAP murid kelas + statusnya hari itu. Murid yang
-- belum punya baris (hari belum ditutup) -> status NULL = "belum ditandai"
-- (UI menampilkannya sebagai default Hadir, tapi data jujur: belum final).
-- Juga ikut mengembalikan keadaan hari lewat kolom yang sama tiap baris.
CREATE OR REPLACE FUNCTION rekap_absensi_hari(p_kelas_id UUID, p_tanggal DATE DEFAULT NULL)
RETURNS TABLE (
  murid_id    UUID,
  nama        TEXT,
  status      TEXT,
  catatan     TEXT,
  tanggal     DATE,
  keadaan     TEXT,
  is_minggu   BOOLEAN
)
LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  WITH t AS (SELECT COALESCE(p_tanggal, CURRENT_DATE) AS d),
       hk AS (
         SELECT ah.keadaan
         FROM absensi_hari ah, t
         WHERE ah.kelas_id = p_kelas_id AND ah.tanggal = t.d
       )
  SELECT
    m.id,
    m.nama,
    a.status,
    a.catatan,
    t.d,
    COALESCE((SELECT keadaan FROM hk), 'belum') AS keadaan,
    (EXTRACT(DOW FROM t.d) = 0) AS is_minggu
  FROM murid m
  CROSS JOIN t
  LEFT JOIN absensi a
    ON a.murid_id = m.id AND a.tanggal = t.d
  WHERE m.kelas_id = p_kelas_id
    AND is_guru_di_kelas(p_kelas_id)   -- penjaga: hanya guru kelas ini
  ORDER BY m.nama;
$$;

-- ── REKAP 1 murid sepanjang rentang (untuk ORTU — dipakai di Fase 2) ──
-- Hanya menampilkan hari yang relevan (ada baris absensi). Dipasang
-- sekarang agar Fase 2 tinggal membuat halaman.
CREATE OR REPLACE FUNCTION rekap_absensi_murid(
  p_murid_id UUID,
  p_dari     DATE DEFAULT NULL,
  p_sampai   DATE DEFAULT NULL
)
RETURNS TABLE (
  tanggal DATE,
  status  TEXT,
  catatan TEXT
)
LANGUAGE sql SECURITY DEFINER SET search_path = public STABLE AS $$
  SELECT a.tanggal, a.status, a.catatan
  FROM absensi a
  WHERE a.murid_id = p_murid_id
    AND boleh_lihat_absensi_murid(p_murid_id)
    AND (p_dari   IS NULL OR a.tanggal >= p_dari)
    AND (p_sampai IS NULL OR a.tanggal <= p_sampai)
  ORDER BY a.tanggal DESC;
$$;

-- Trigger perbarui timestamp pada absensi
DROP TRIGGER IF EXISTS tr_absensi_diperbarui ON absensi;
CREATE TRIGGER tr_absensi_diperbarui BEFORE UPDATE ON absensi
  FOR EACH ROW EXECUTE FUNCTION update_diperbarui_pada();


-- ================================================================
-- BAGIAN 6: HAK AKSES (GRANT) — wajib (auto-expose dimatikan)
-- ================================================================

GRANT SELECT ON public.absensi      TO authenticated;
GRANT SELECT ON public.absensi_hari TO authenticated;
-- INSERT/UPDATE/DELETE sengaja TIDAK di-grant: semua tulis lewat RPC.

GRANT EXECUTE ON FUNCTION boleh_lihat_absensi_murid(UUID)        TO authenticated;
GRANT EXECUTE ON FUNCTION _absensi_boleh_dicatat(UUID, DATE)     TO authenticated;
GRANT EXECUTE ON FUNCTION set_absensi_murid(UUID, TEXT, TEXT)    TO authenticated;
GRANT EXECUTE ON FUNCTION tutup_absensi(UUID)                    TO authenticated;
GRANT EXECUTE ON FUNCTION buka_absensi(UUID)                     TO authenticated;
GRANT EXECUTE ON FUNCTION set_hari_libur(UUID, BOOLEAN)          TO authenticated;
GRANT EXECUTE ON FUNCTION rekap_absensi_hari(UUID, DATE)         TO authenticated;
GRANT EXECUTE ON FUNCTION rekap_absensi_murid(UUID, DATE, DATE)  TO authenticated;


-- ================================================================
-- SELESAI! Tahap 2 (Absensi sisi guru) siap.
-- Halaman: pages/absensi.html. Notif & layar ortu = Fase 2.
-- ================================================================
