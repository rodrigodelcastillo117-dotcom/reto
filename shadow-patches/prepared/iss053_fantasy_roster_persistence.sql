-- iss053 — NFL FANTASY roster persistence hardening · STAGED
-- Owner goal: a confirmed roster survives reload/device changes and a later screenshot
-- replaces the current week deterministically instead of accumulating duplicates.
-- No model logic here.

-- Existing frontend uses upsert(..., onConflict: 'apodo,temporada,semana').
-- The production table currently has no matching unique constraint, so Supabase/PostgREST
-- cannot honor that upsert and the UI silently falls back to localStorage.
-- This constraint is the missing cloud-persistence contract.

DO $$
BEGIN
  IF to_regclass('public.fantasy_roster_semanal') IS NULL THEN
    RAISE EXCEPTION 'fantasy_roster_semanal missing';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.fantasy_roster_semanal
    GROUP BY apodo, temporada, semana HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'duplicate roster rows exist for apodo/temporada/semana; reconcile before constraint';
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS fantasy_roster_semanal_owner_week_uk
  ON public.fantasy_roster_semanal(apodo, temporada, semana);

CREATE OR REPLACE FUNCTION public.tg_fantasy_roster_touch_guardado_at()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO public
AS $$
BEGIN
  NEW.guardado_at := now();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS fantasy_roster_touch_guardado_at ON public.fantasy_roster_semanal;
CREATE TRIGGER fantasy_roster_touch_guardado_at
BEFORE UPDATE ON public.fantasy_roster_semanal
FOR EACH ROW EXECUTE FUNCTION public.tg_fantasy_roster_touch_guardado_at();

COMMENT ON INDEX public.fantasy_roster_semanal_owner_week_uk IS
  'One canonical current roster per user/season/week; enables PostgREST upsert from Remix Reto 13M.';
