-- ================================================================
-- GuruIndo — Tahap 2b: PENGAJUAN IZIN/SAKIT + NOTIFIKASI
-- ================================================================
-- ⚠️ STATUS: REKONSTRUKSI dari Supabase (file asli hilang dari ZIP).
--
-- Cara file ini dibuat: query information_schema + pg_get_functiondef
-- pada DB Supabase yang sedang LIVE. Isinya MATCH dengan kondisi DB
-- per 11 Juni 2026 (5 baris pengajuan & 5 baris notifikasi sudah ada).
--
-- Aman dijalankan ulang di DB ini (CREATE OR REPLACE / IF NOT EXISTS
-- / ON CONFLICT membuatnya no-op).
--
-- ✅ FILE INI SELF-CONTAINED (sepanjang setup.sql + tahap2-absensi.sql
--    sudah ada lebih dulu): tabel notifikasi + pengajuan_izin, RLS,
--    11 fungsi (1 helper internal + 10 RPC), GRANT.
--
-- File pelengkap untuk fitur read-receipts catatan (tabel dibaca_thread
-- + 3 fungsi Kelompok B) ada di: sql/tahap1c-read-receipts.sql
--
-- ❗ ITEM "BEST-EFFORT" (tidak 100% terverifikasi dari hasil query):
--    * DEFAULT NOW() pada kolom *_pada  — pola umum, match tahap2-absensi
--    * ON DELETE CASCADE/SET NULL pada FK — match pola setup.sql
--    Kalau migrate ke DB bersih dan ternyata salah, sesuaikan sebelum jalan.
-- ================================================================


-- ================================================================
-- BAGIAN 1: TABEL
-- ================================================================

-- (A) notifikasi  — untuk ORTU saja (kolom ortu_id NOT NULL).
--     jenis: 'absensi' (anak absen) | 'pengajuan' (pengajuan diputus)
--     dibaca_pada: NULL = belum dibaca; TIMESTAMPTZ = waktu dibacanya
--     UNIQUE (ortu_id, murid_id, tanggal, jenis) -> idempoten anti-dobel
CREATE TABLE IF NOT EXISTS notifikasi (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ortu_id     UUID NOT NULL REFERENCES profil(id) ON DELETE CASCADE,
  jenis       TEXT NOT NULL DEFAULT 'absensi'
                CHECK (jenis IN ('absensi', 'pengajuan')),
  murid_id    UUID REFERENCES murid(id) ON DELETE CASCADE,
  tanggal     DATE,
  judul       TEXT NOT NULL,
  isi         TEXT NOT NULL,
  tautan      TEXT,
  dibaca_pada TIMESTAMPTZ,
  dibuat_pada TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE (ortu_id, murid_id, tanggal, jenis)
);

CREATE INDEX IF NOT EXISTS idx_notifikasi_ortu
  ON notifikasi (ortu_id, dibuat_pada DESC);

CREATE INDEX IF NOT EXISTS idx_notifikasi_belum_dibaca
  ON notifikasi (ortu_id) WHERE dibaca_pada IS NULL;


-- (B) pengajuan_izin  — pengajuan izin/sakit dari ortu.
--     kelas_id WAJIB (snapshot kelas saat diajukan; tahan murid pindah kelas)
--     diajukan_oleh = ortu_id pengaju; diputus_oleh = guru pemutus
--     status: 'menunggu' (awal) -> 'disetujui' | 'ditolak' (final)
CREATE TABLE IF NOT EXISTS pengajuan_izin (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  murid_id      UUID NOT NULL REFERENCES murid(id) ON DELETE CASCADE,
  kelas_id      UUID NOT NULL REFERENCES kelas(id) ON DELETE CASCADE,
  diajukan_oleh UUID NOT NULL REFERENCES profil(id) ON DELETE CASCADE,
  jenis_izin    TEXT NOT NULL
                  CHECK (jenis_izin IN ('izin', 'sakit')),
  tgl_dari      DATE NOT NULL,
  tgl_sampai    DATE NOT NULL,
  alasan        TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'menunggu'
                  CHECK (status IN ('menunggu', 'disetujui', 'ditolak')),
  diputus_oleh  UUID REFERENCES profil(id) ON DELETE SET NULL,
  catatan_guru  TEXT,
  dibuat_pada   TIMESTAMPTZ DEFAULT NOW(),
  diputus_pada  TIMESTAMPTZ,
  foto_path     TEXT,
  CONSTRAINT cek_rentang CHECK (tgl_sampai >= tgl_dari)
);

CREATE INDEX IF NOT EXISTS idx_pengajuan_murid
  ON pengajuan_izin (murid_id, dibuat_pada DESC);

CREATE INDEX IF NOT EXISTS idx_pengajuan_kelas_status
  ON pengajuan_izin (kelas_id, status, dibuat_pada DESC);


-- ================================================================
-- BAGIAN 2: AKTIFKAN RLS
-- ================================================================

ALTER TABLE notifikasi     ENABLE ROW LEVEL SECURITY;
ALTER TABLE pengajuan_izin ENABLE ROW LEVEL SECURITY;


-- ================================================================
-- BAGIAN 3: KEBIJAKAN RLS (memakai helper SECURITY DEFINER dari setup.sql)
-- ================================================================

-- ── notifikasi: hanya pemiliknya yang lihat & update (untuk tandai dibaca) ──
DROP POLICY IF EXISTS "notifikasi_select_own" ON notifikasi;
CREATE POLICY "notifikasi_select_own" ON notifikasi FOR SELECT
  USING (ortu_id = auth.uid());

DROP POLICY IF EXISTS "notifikasi_update_own" ON notifikasi;
CREATE POLICY "notifikasi_update_own" ON notifikasi FOR UPDATE
  USING (ortu_id = auth.uid());

-- ── pengajuan_izin: ortu lihat pengajuan anaknya; guru lihat pengajuan kelasnya ──
DROP POLICY IF EXISTS "pengajuan_select_ortu" ON pengajuan_izin;
CREATE POLICY "pengajuan_select_ortu" ON pengajuan_izin FOR SELECT
  USING (is_ortu_dari_murid(murid_id));

DROP POLICY IF EXISTS "pengajuan_select_guru" ON pengajuan_izin;
CREATE POLICY "pengajuan_select_guru" ON pengajuan_izin FOR SELECT
  USING (is_guru_di_kelas(kelas_id));


-- ================================================================
-- BAGIAN 4: FUNGSI PENGAJUAN (sisi ortu)
-- ================================================================
-- ⚠️ Sumber kebenaran fungsi-fungsi di bawah ini adalah pg_get_functiondef()
-- pada DB Supabase. Body fungsi MATCH-CARBON dengan yang ada di DB.

CREATE OR REPLACE FUNCTION public.ajukan_izin(
  p_murid_id   uuid,
  p_jenis      text,
  p_tgl_dari   date,
  p_tgl_sampai date,
  p_alasan     text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_kelas_id UUID;
  v_id       UUID;
BEGIN
  -- Hanya ortu (wali) murid ini
  IF NOT is_ortu_dari_murid(p_murid_id) THEN
    RAISE EXCEPTION 'Kamu bukan wali murid ini';
  END IF;
  IF p_jenis NOT IN ('izin', 'sakit') THEN
    RAISE EXCEPTION 'Jenis hanya boleh izin atau sakit';
  END IF;
  IF p_alasan IS NULL OR trim(p_alasan) = '' THEN
    RAISE EXCEPTION 'Mohon isi alasannya dulu';
  END IF;
  IF p_tgl_dari IS NULL OR p_tgl_sampai IS NULL THEN
    RAISE EXCEPTION 'Tanggal belum lengkap';
  END IF;
  -- Tanggal lampau ditolak; mulai hari ini ke depan
  IF p_tgl_dari < CURRENT_DATE THEN
    RAISE EXCEPTION 'Tidak bisa mengajukan untuk tanggal yang sudah lewat';
  END IF;
  IF p_tgl_sampai < p_tgl_dari THEN
    RAISE EXCEPTION 'Tanggal selesai tidak boleh sebelum tanggal mulai';
  END IF;

  SELECT kelas_id INTO v_kelas_id FROM murid WHERE id = p_murid_id;
  IF v_kelas_id IS NULL THEN
    RAISE EXCEPTION 'Murid tidak ditemukan';
  END IF;

  -- Cegah pengajuan ganda yang masih menunggu & rentangnya beririsan
  IF EXISTS (
    SELECT 1 FROM pengajuan_izin
    WHERE murid_id = p_murid_id
      AND status = 'menunggu'
      AND tgl_dari <= p_tgl_sampai
      AND tgl_sampai >= p_tgl_dari
  ) THEN
    RAISE EXCEPTION 'Sudah ada pengajuan menunggu untuk tanggal yang beririsan';
  END IF;

  INSERT INTO pengajuan_izin
    (murid_id, kelas_id, diajukan_oleh, jenis_izin, tgl_dari, tgl_sampai, alasan)
  VALUES
    (p_murid_id, v_kelas_id, auth.uid(), p_jenis, p_tgl_dari, p_tgl_sampai, trim(p_alasan))
  RETURNING id INTO v_id;

  RETURN jsonb_build_object('berhasil', TRUE, 'pengajuan_id', v_id);
END;
$function$;


CREATE OR REPLACE FUNCTION public.set_foto_pengajuan(
  p_pengajuan_id uuid,
  p_path         text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v pengajuan_izin%ROWTYPE;
BEGIN
  SELECT * INTO v FROM pengajuan_izin WHERE id = p_pengajuan_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'Pengajuan tidak ditemukan';
  END IF;
  IF NOT is_ortu_dari_murid(v.murid_id) THEN
    RAISE EXCEPTION 'Kamu bukan wali murid ini';
  END IF;
  IF v.status <> 'menunggu' THEN
    RAISE EXCEPTION 'Pengajuan sudah diputuskan, foto tidak bisa diubah';
  END IF;
  -- Path WAJIB diawali "<murid_id>/" — cegah catat path milik murid lain
  IF p_path IS NULL OR p_path NOT LIKE (v.murid_id::text || '/%') THEN
    RAISE EXCEPTION 'Path foto tidak sah';
  END IF;

  UPDATE pengajuan_izin SET foto_path = p_path WHERE id = p_pengajuan_id;
  RETURN jsonb_build_object('berhasil', TRUE);
END;
$function$;


CREATE OR REPLACE FUNCTION public.daftar_pengajuan_anak(p_murid_id uuid)
RETURNS TABLE (
  id           uuid,
  jenis_izin   text,
  tgl_dari     date,
  tgl_sampai   date,
  alasan       text,
  status       text,
  catatan_guru text,
  foto_path    text,
  dibuat_pada  timestamp with time zone
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT id, jenis_izin, tgl_dari, tgl_sampai, alasan, status, catatan_guru,
         foto_path, dibuat_pada
  FROM pengajuan_izin
  WHERE murid_id = p_murid_id
    AND is_ortu_dari_murid(p_murid_id)
  ORDER BY dibuat_pada DESC;
$function$;


-- ================================================================
-- BAGIAN 5: FUNGSI PENGAJUAN (sisi guru)
-- ================================================================

CREATE OR REPLACE FUNCTION public.daftar_pengajuan_kelas(p_kelas_id uuid)
RETURNS TABLE (
  id          uuid,
  murid_id    uuid,
  nama_murid  text,
  jenis_izin  text,
  tgl_dari    date,
  tgl_sampai  date,
  alasan      text,
  foto_path   text,
  dibuat_pada timestamp with time zone
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT p.id, p.murid_id, m.nama, p.jenis_izin, p.tgl_dari, p.tgl_sampai,
         p.alasan, p.foto_path, p.dibuat_pada
  FROM pengajuan_izin p
  JOIN murid m ON m.id = p.murid_id
  WHERE p.kelas_id = p_kelas_id
    AND p.status = 'menunggu'
    AND is_guru_di_kelas(p_kelas_id)
  ORDER BY p.dibuat_pada ASC;
$function$;


CREATE OR REPLACE FUNCTION public.pengajuan_menunggu_guru()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COUNT(*)::INT
  FROM pengajuan_izin p
  JOIN guru_kelas gk ON gk.kelas_id = p.kelas_id
  WHERE gk.guru_id = auth.uid() AND p.status = 'menunggu';
$function$;


-- ── Helper internal: set 1 baris absensi pada 1 tanggal ─────────
-- Dipakai putus_pengajuan saat menyetujui pengajuan (loop per tanggal).
-- Skip Minggu & hari yang sudah ditandai 'libur' di absensi_hari.
-- Memastikan baris absensi_hari ada (tidak menimpa kalau sudah 'ditutup'),
-- lalu UPSERT baris absensi murid. RETURN TRUE = baris di-set, FALSE = di-skip.
CREATE OR REPLACE FUNCTION public._set_absensi_tanggal(
  p_murid_id uuid,
  p_kelas_id uuid,
  p_tanggal  date,
  p_status   text,
  p_catatan  text,
  p_oleh     uuid
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  -- Lewati hari Minggu
  IF EXTRACT(DOW FROM p_tanggal) = 0 THEN
    RETURN FALSE;
  END IF;
  -- Lewati hari yang ditandai 'libur'
  IF EXISTS (
    SELECT 1 FROM absensi_hari
    WHERE kelas_id = p_kelas_id AND tanggal = p_tanggal AND keadaan = 'libur'
  ) THEN
    RETURN FALSE;
  END IF;

  -- Pastikan baris hari ada (jangan ubah keadaan bila sudah 'ditutup')
  INSERT INTO absensi_hari (kelas_id, tanggal, keadaan, diubah_oleh)
  VALUES (p_kelas_id, p_tanggal, 'belum', p_oleh)
  ON CONFLICT (kelas_id, tanggal) DO NOTHING;

  -- UPSERT status murid pada tanggal itu
  INSERT INTO absensi (murid_id, kelas_id, tanggal, status, catatan, dicatat_oleh)
  VALUES (p_murid_id, p_kelas_id, p_tanggal, p_status,
          NULLIF(trim(COALESCE(p_catatan,'')),''), p_oleh)
  ON CONFLICT (murid_id, tanggal)
  DO UPDATE SET
    status          = EXCLUDED.status,
    catatan         = EXCLUDED.catatan,
    kelas_id        = EXCLUDED.kelas_id,
    dicatat_oleh    = EXCLUDED.dicatat_oleh,
    diperbarui_pada = NOW();

  RETURN TRUE;
END;
$function$;


CREATE OR REPLACE FUNCTION public.putus_pengajuan(
  p_pengajuan_id uuid,
  p_setujui      boolean,
  p_catatan      text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v       pengajuan_izin%ROWTYPE;
  v_nama  TEXT;
  v_d     DATE;
  v_jml   INT := 0;
  v_label TEXT;
  v_judul TEXT;
  v_isi   TEXT;
BEGIN
  SELECT * INTO v FROM pengajuan_izin WHERE id = p_pengajuan_id;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'Pengajuan tidak ditemukan';
  END IF;
  -- Hanya guru di kelas pengajuan itu
  IF NOT is_guru_di_kelas(v.kelas_id) THEN
    RAISE EXCEPTION 'Hanya guru kelas ini yang bisa memutuskan';
  END IF;
  -- Idempoten: tak bisa memutus yang sudah diputus
  IF v.status <> 'menunggu' THEN
    RAISE EXCEPTION 'Pengajuan ini sudah diputuskan sebelumnya';
  END IF;

  SELECT nama INTO v_nama FROM murid WHERE id = v.murid_id;

  IF p_setujui THEN
    -- Set absensi tiap tanggal rentang (lewati Minggu/libur)
    v_d := v.tgl_dari;
    WHILE v_d <= v.tgl_sampai LOOP
      IF _set_absensi_tanggal(
           v.murid_id, v.kelas_id, v_d, v.jenis_izin,
           v.jenis_izin || ' (disetujui dari pengajuan ortu)', auth.uid()
         ) THEN
        v_jml := v_jml + 1;
      END IF;
      v_d := v_d + 1;
    END LOOP;

    UPDATE pengajuan_izin
    SET status = 'disetujui', diputus_oleh = auth.uid(),
        catatan_guru = NULLIF(trim(COALESCE(p_catatan,'')),''), diputus_pada = NOW()
    WHERE id = p_pengajuan_id;

    v_label := CASE v.jenis_izin WHEN 'sakit' THEN 'sakit' ELSE 'izin' END;
    v_judul := 'Pengajuan ' || v_label || ' disetujui';
    v_isi   := 'Pengajuan ' || v_label || ' untuk ' || COALESCE(v_nama,'anak')
               || ' (' || to_char(v.tgl_dari,'DD Mon') || ' - '
               || to_char(v.tgl_sampai,'DD Mon YYYY') || ') telah disetujui guru.';
  ELSE
    UPDATE pengajuan_izin
    SET status = 'ditolak', diputus_oleh = auth.uid(),
        catatan_guru = NULLIF(trim(COALESCE(p_catatan,'')),''), diputus_pada = NOW()
    WHERE id = p_pengajuan_id;

    v_label := CASE v.jenis_izin WHEN 'sakit' THEN 'sakit' ELSE 'izin' END;
    v_judul := 'Pengajuan ' || v_label || ' ditolak';
    v_isi   := 'Pengajuan ' || v_label || ' untuk ' || COALESCE(v_nama,'anak')
               || ' (' || to_char(v.tgl_dari,'DD Mon') || ' - '
               || to_char(v.tgl_sampai,'DD Mon YYYY') || ') ditolak guru.'
               || COALESCE(' Catatan: ' || NULLIF(trim(COALESCE(p_catatan,'')),''), '');
  END IF;

  -- Notif ke SEMUA ortu anak (jenis 'pengajuan'; murid_id+tanggal NULL ->
  -- tidak bentrok unique idempotensi absensi). tautan ke halaman anak.
  INSERT INTO notifikasi (ortu_id, jenis, murid_id, tanggal, judul, isi, tautan)
  SELECT om.ortu_id, 'pengajuan', v.murid_id, NULL, v_judul, v_isi,
         'absensi-anak.html?murid=' || v.murid_id::text
  FROM ortu_murid om
  WHERE om.murid_id = v.murid_id;

  RETURN jsonb_build_object('berhasil', TRUE, 'disetujui', p_setujui, 'hari_tercatat', v_jml);
END;
$function$;


-- ================================================================
-- BAGIAN 6: FUNGSI NOTIFIKASI (sisi ortu)
-- ================================================================

CREATE OR REPLACE FUNCTION public.daftar_notif(p_limit integer DEFAULT 50)
RETURNS TABLE (
  id          uuid,
  jenis       text,
  murid_id    uuid,
  tanggal     date,
  judul       text,
  isi         text,
  tautan      text,
  dibaca      boolean,
  dibuat_pada timestamp with time zone
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    n.id, n.jenis, n.murid_id, n.tanggal, n.judul, n.isi, n.tautan,
    (n.dibaca_pada IS NOT NULL) AS dibaca,
    n.dibuat_pada
  FROM notifikasi n
  WHERE n.ortu_id = auth.uid()
  ORDER BY n.dibuat_pada DESC
  LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 50), 200));
$function$;


CREATE OR REPLACE FUNCTION public.notif_belum_dibaca()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COUNT(*)::INT FROM notifikasi
  WHERE ortu_id = auth.uid() AND dibaca_pada IS NULL;
$function$;


CREATE OR REPLACE FUNCTION public.tandai_notif_dibaca(p_notif_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE notifikasi
  SET dibaca_pada = NOW()
  WHERE id = p_notif_id AND ortu_id = auth.uid() AND dibaca_pada IS NULL;
  RETURN jsonb_build_object('berhasil', TRUE);
END;
$function$;


CREATE OR REPLACE FUNCTION public.tandai_semua_notif_dibaca()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE v_jumlah INT;
BEGIN
  UPDATE notifikasi
  SET dibaca_pada = NOW()
  WHERE ortu_id = auth.uid() AND dibaca_pada IS NULL;
  GET DIAGNOSTICS v_jumlah = ROW_COUNT;
  RETURN jsonb_build_object('berhasil', TRUE, 'jumlah', v_jumlah);
END;
$function$;


-- ================================================================
-- BAGIAN 7: HAK AKSES (GRANT) — wajib (auto-expose dimatikan)
-- ================================================================
-- Diverifikasi via information_schema.role_table_grants pada DB Supabase:
-- authenticated SUDAH punya SELECT (notifikasi & pengajuan_izin) + UPDATE
-- (notifikasi, untuk policy notifikasi_update_own).
-- Aman dideklarasikan ulang (GRANT ke role yang sudah punya = no-op).

GRANT SELECT, UPDATE ON public.notifikasi     TO authenticated;
GRANT SELECT         ON public.pengajuan_izin TO authenticated;
-- INSERT/DELETE sengaja TIDAK di-grant: semua tulis lewat RPC SECURITY DEFINER.

-- Catatan: GRANT EXECUTE pada fungsi-fungsi di atas sudah ada di DB
-- (kalau tidak, frontend tidak bisa memanggilnya — & faktanya 5 baris
-- data sudah masuk lewat ajukan_izin). Tetap dideklarasikan ulang
-- untuk dokumentasi / migrasi.
-- _set_absensi_tanggal helper internal: tidak dipanggil dari frontend,
-- hanya dari putus_pengajuan (SECURITY DEFINER, jalan sebagai owner DB),
-- jadi tidak perlu GRANT EXECUTE ke authenticated.

GRANT EXECUTE ON FUNCTION public.ajukan_izin(uuid, text, date, date, text)        TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_foto_pengajuan(uuid, text)                   TO authenticated;
GRANT EXECUTE ON FUNCTION public.daftar_pengajuan_anak(uuid)                      TO authenticated;
GRANT EXECUTE ON FUNCTION public.daftar_pengajuan_kelas(uuid)                     TO authenticated;
GRANT EXECUTE ON FUNCTION public.pengajuan_menunggu_guru()                        TO authenticated;
GRANT EXECUTE ON FUNCTION public.putus_pengajuan(uuid, boolean, text)             TO authenticated;
GRANT EXECUTE ON FUNCTION public.daftar_notif(integer)                            TO authenticated;
GRANT EXECUTE ON FUNCTION public.notif_belum_dibaca()                             TO authenticated;
GRANT EXECUTE ON FUNCTION public.tandai_notif_dibaca(uuid)                        TO authenticated;
GRANT EXECUTE ON FUNCTION public.tandai_semua_notif_dibaca()                      TO authenticated;


-- ================================================================
-- ✅ FILE INI SUDAH SELF-CONTAINED
-- ================================================================
-- Dependency `_set_absensi_tanggal` sekarang ada di BAGIAN 5 di atas
-- (sebelum putus_pengajuan). Untuk migrate ke DB bersih, jalankan
-- file SQL dalam urutan ini:
--
--   1. setup.sql
--   2. fix_rls_recursion.sql
--   3. tahap1a.sql
--   4. tahap1b.sql
--   5. tahap2-absensi.sql
--   6. tahap2b-pengajuan-notif.sql       <-- file ini
--   7. tahap1c-read-receipts.sql         <-- tabel dibaca_thread + 3 fungsi catatan
-- ================================================================
