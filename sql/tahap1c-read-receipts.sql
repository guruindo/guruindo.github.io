-- ================================================================
-- GuruIndo — Tahap 1c: READ RECEIPTS CATATAN + TOGGLE BALAS
-- ================================================================
-- ⚠️ STATUS: REKONSTRUKSI dari Supabase (file asli hilang dari ZIP).
--
-- Cara file ini dibuat: query information_schema + pg_get_functiondef
-- pada DB Supabase yang sedang LIVE per 11 Juni 2026.
-- Aman dijalankan ulang (CREATE OR REPLACE / IF NOT EXISTS membuatnya no-op).
--
-- ISI:
--   * Tabel `dibaca_thread`  — catat kapan tiap user terakhir baca thread
--     catatan personal 1 anak. 1 baris per (murid_id, pembaca_id).
--   * 4 fungsi RPC:
--       - tandai_thread_dibaca(p_murid_id)        : update timestamp baca
--       - status_baca_thread(p_murid_id)          : kapan LAWAN terakhir baca
--                                                   (utk centang ✓✓)
--       - catatan_belum_dibaca()                  : jumlah thread dgn pesan
--                                                   lawan yg belum dibaca user
--                                                   (badge di beranda)
--       - set_boleh_balas_terakhir(murid_id,bool) : guru toggle balas-tidak
--                                                   pada pesan TERAKHIRnya
--
-- DEPENDENCY (harus sudah ada sebelum file ini dijalankan di DB bersih):
--   * setup.sql: tabel profil, murid, helper is_guru_dari_murid,
--                is_ortu_dari_murid, peran_saya
--   * tahap1a.sql: tabel guru_kelas
--   * tahap1b.sql: tabel pesan dgn kolom (id, jenis, murid_id, pengirim_id,
--                  balas_dari_id, boleh_balas, dibuat_pada)
--
-- ❗ ITEM "BEST-EFFORT" (tidak 100% terverifikasi dari hasil query):
--   * ON DELETE CASCADE pada FK (sesuai pola setup.sql)
--   Selebihnya (kolom, default, constraint, index, policy) terverifikasi
--   langsung dari hasil query DB.
-- ================================================================


-- ================================================================
-- BAGIAN 1: TABEL dibaca_thread
-- ================================================================
-- 1 baris per (murid_id, pembaca_id): kapan TERAKHIR si pembaca buka
-- thread catatan personal untuk murid itu. Dipakai untuk:
--   a) Centang ✓✓ di catatan-thread (lewat status_baca_thread)
--   b) Badge unread di beranda (lewat catatan_belum_dibaca)

CREATE TABLE IF NOT EXISTS dibaca_thread (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  murid_id    UUID NOT NULL REFERENCES murid(id)  ON DELETE CASCADE,
  pembaca_id  UUID NOT NULL REFERENCES profil(id) ON DELETE CASCADE,
  dibaca_pada TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (murid_id, pembaca_id)
);

CREATE INDEX IF NOT EXISTS idx_dibaca_thread_murid
  ON dibaca_thread (murid_id);


-- ================================================================
-- BAGIAN 2: AKTIFKAN RLS
-- ================================================================

ALTER TABLE dibaca_thread ENABLE ROW LEVEL SECURITY;


-- ================================================================
-- BAGIAN 3: KEBIJAKAN RLS
-- ================================================================
-- SELECT saja: guru pengajar atau ortu wali murid ybs.
-- Tulis (INSERT/UPDATE) lewat tandai_thread_dibaca (SECURITY DEFINER),
-- jadi tak butuh policy tulis.

DROP POLICY IF EXISTS "dibaca_thread_baca" ON dibaca_thread;
CREATE POLICY "dibaca_thread_baca" ON dibaca_thread FOR SELECT
  USING (is_guru_dari_murid(murid_id) OR is_ortu_dari_murid(murid_id));


-- ================================================================
-- BAGIAN 4: FUNGSI RPC
-- ================================================================

-- ── Tandai thread 1 anak sudah dibaca (pemanggil = pembaca) ──
-- Pertama buka thread -> INSERT. Buka lagi -> UPDATE dibaca_pada.
-- Pemanggil HARUS pihak terkait murid ini (guru pengajar / ortu wali).
CREATE OR REPLACE FUNCTION public.tandai_thread_dibaca(p_murid_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NOT (is_guru_dari_murid(p_murid_id) OR is_ortu_dari_murid(p_murid_id)) THEN
    RAISE EXCEPTION 'Kamu tidak punya akses ke catatan murid ini';
  END IF;

  INSERT INTO dibaca_thread (murid_id, pembaca_id, dibaca_pada)
  VALUES (p_murid_id, auth.uid(), NOW())
  ON CONFLICT (murid_id, pembaca_id)
  DO UPDATE SET dibaca_pada = NOW();

  RETURN jsonb_build_object('berhasil', TRUE);
END;
$function$;


-- ── Kapan LAWAN terakhir baca thread (untuk centang ✓✓ di pesanku) ──
-- Pemanggil guru -> lawan = wali (ortu_murid). Pemanggil ortu -> lawan
-- = guru pengajar (guru_kelas). Ambil MAX dibaca_pada di antara mereka.
-- Return NULL = lawan belum pernah baca (= ✓ saja, belum ✓✓).
CREATE OR REPLACE FUNCTION public.status_baca_thread(p_murid_id uuid)
RETURNS timestamp with time zone
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_peran TEXT;
  v_hasil TIMESTAMPTZ;
BEGIN
  -- Pemanggil harus pihak terkait murid ini.
  IF NOT (is_guru_dari_murid(p_murid_id) OR is_ortu_dari_murid(p_murid_id)) THEN
    RAISE EXCEPTION 'Kamu tidak punya akses ke catatan murid ini';
  END IF;

  v_peran := peran_saya();

  IF v_peran = 'guru' THEN
    -- Lawan = para WALI murid ini.
    SELECT MAX(dt.dibaca_pada) INTO v_hasil
    FROM dibaca_thread dt
    JOIN ortu_murid om
      ON om.murid_id = dt.murid_id AND om.ortu_id = dt.pembaca_id
    WHERE dt.murid_id = p_murid_id;
  ELSE
    -- Lawan = para GURU yang mengajar di kelas murid ini.
    SELECT MAX(dt.dibaca_pada) INTO v_hasil
    FROM dibaca_thread dt
    JOIN murid m       ON m.id = dt.murid_id
    JOIN guru_kelas gk ON gk.kelas_id = m.kelas_id AND gk.guru_id = dt.pembaca_id
    WHERE dt.murid_id = p_murid_id;
  END IF;

  RETURN v_hasil;  -- bisa NULL = belum pernah dibaca lawan
END;
$function$;


-- ── Hitung thread yang ada pesan LAWAN belum dibaca (badge beranda) ──
-- Distinct per murid: kalau 1 anak punya 3 pesan baru, dihitung 1 thread.
-- Pesan yang sudah lebih lama dari dibaca_pada terakhir user -> dianggap
-- sudah dibaca. Belum pernah baca sama sekali -> COALESCE ke 'epoch'.
CREATE OR REPLACE FUNCTION public.catatan_belum_dibaca()
RETURNS integer
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COUNT(DISTINCT p.murid_id)::INTEGER
  FROM pesan p
  LEFT JOIN dibaca_thread dt
    ON dt.murid_id = p.murid_id AND dt.pembaca_id = auth.uid()
  WHERE p.jenis = 'personal'
    AND p.pengirim_id <> auth.uid()                      -- hanya pesan LAWAN
    AND (is_guru_dari_murid(p.murid_id)                  -- thread yang boleh kuakses
         OR is_ortu_dari_murid(p.murid_id))
    AND p.dibuat_pada > COALESCE(dt.dibaca_pada, 'epoch'::timestamptz);
$function$;


-- ── Guru toggle: izinkan/larang ortu balas pesan TERAKHIRku ──
-- "Pesan terakhir" = pesan personal pengirim_id=guru di thread murid ini,
-- yang BUKAN balasan (balas_dari_id NULL), urut waktu terbaru.
-- Kalau belum pernah ada pesan guru di thread itu -> return TIDAK_ADA_PESAN
-- (frontend handle ini dgn toast warning, tidak melempar error).
CREATE OR REPLACE FUNCTION public.set_boleh_balas_terakhir(
  p_murid_id uuid,
  p_boleh    boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_pesan_id UUID;
BEGIN
  -- Hanya guru, dan hanya guru yang mengajar murid ini.
  IF peran_saya() <> 'guru' THEN
    RAISE EXCEPTION 'Hanya guru yang bisa mengubah ini';
  END IF;
  IF NOT is_guru_dari_murid(p_murid_id) THEN
    RAISE EXCEPTION 'Kamu tidak mengajar murid ini';
  END IF;

  -- Cari pesan GURU terakhir (bukan balasan) di thread murid ini.
  SELECT id INTO v_pesan_id
  FROM pesan
  WHERE jenis = 'personal'
    AND murid_id = p_murid_id
    AND pengirim_id = auth.uid()
    AND balas_dari_id IS NULL
  ORDER BY dibuat_pada DESC
  LIMIT 1;

  -- Belum ada pesan guru sama sekali -> tak ada yang bisa dibuka/ditutup.
  IF v_pesan_id IS NULL THEN
    RETURN jsonb_build_object('berhasil', FALSE, 'kode', 'TIDAK_ADA_PESAN');
  END IF;

  UPDATE pesan
  SET boleh_balas = COALESCE(p_boleh, TRUE)
  WHERE id = v_pesan_id;

  RETURN jsonb_build_object(
    'berhasil', TRUE, 'kode', 'OK',
    'pesan_id', v_pesan_id, 'boleh_balas', COALESCE(p_boleh, TRUE)
  );
END;
$function$;


-- ================================================================
-- BAGIAN 5: HAK AKSES (GRANT)
-- ================================================================
-- Tabel tidak butuh GRANT INSERT/UPDATE/DELETE: semua tulis lewat
-- tandai_thread_dibaca (SECURITY DEFINER, jalan sebagai owner DB).
-- SELECT diberikan supaya policy "dibaca_thread_baca" bisa ke-evaluate
-- kalau suatu hari ada query langsung dari client (defensive).

GRANT SELECT ON public.dibaca_thread TO authenticated;

GRANT EXECUTE ON FUNCTION public.tandai_thread_dibaca(uuid)              TO authenticated;
GRANT EXECUTE ON FUNCTION public.status_baca_thread(uuid)                TO authenticated;
GRANT EXECUTE ON FUNCTION public.catatan_belum_dibaca()                  TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_boleh_balas_terakhir(uuid, boolean) TO authenticated;


-- ================================================================
-- ✅ SELESAI. File ini self-contained.
--
-- Urutan deploy ke DB bersih:
--   1. setup.sql
--   2. fix_rls_recursion.sql
--   3. tahap1a.sql
--   4. tahap1b.sql
--   5. tahap2-absensi.sql
--   6. tahap2b-pengajuan-notif.sql
--   7. tahap1c-read-receipts.sql      <-- file ini
-- ================================================================
