-- ROLLBACK de sec_hardening_v1. Restaura el estado previo exacto.
-- NO EJECUTAR salvo incidente: revierte a un estado con escritura anónima al ledger.
\set ON_ERROR_STOP on
BEGIN;
GRANT EXECUTE ON FUNCTION public.lab_mlb_fwd_capturar(
  text, timestamptz, text, numeric, text, text, timestamptz, text, numeric, text, text, text) TO PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.lab_mlb_fwd_resultado(
  text, integer, numeric, timestamptz) TO PUBLIC, anon, authenticated;
ALTER FUNCTION public.lab_ff_capturar_semana(integer, integer)             RESET search_path;
ALTER FUNCTION public.lab_ff_capturar_semana_actual()                       RESET search_path;
ALTER FUNCTION public.lab_ff_fwd_capturar_v1(text, text, text, integer, integer, text, text, timestamptz, text, text, text) RESET search_path;
ALTER FUNCTION public.lab_ff_grade_semana(integer, integer)                 RESET search_path;
ALTER FUNCTION public.lab_ff_import_ownership(text, text, integer, integer, jsonb) RESET search_path;
ALTER FUNCTION public.lab_ff_ingest_screenshot(text, integer, integer, text, jsonb) RESET search_path;
ALTER FUNCTION public.lab_mlb_fwd_capturar(text, timestamptz, text, numeric, text, text, timestamptz, text, numeric, text, text, text) RESET search_path;
ALTER FUNCTION public.lab_mlb_fwd_resultado(text, integer, numeric, timestamptz) RESET search_path;
COMMIT;
