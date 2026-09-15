-- ============================================================================
-- ROLLBACK TOP_PICK_FORWARD_CAPTURE_V1 v3 (SHADOW / solo LAB branch)
-- Elimina SOLO los objetos nuevos de v3. Sin CASCADE a objetos canónicos.
-- v_pick_canonico / economic_* / oraculo_picks_tracking / analisis_partidos y
-- sus triggers existentes quedan INTACTOS. No revierte P/EV/es_pick/stake.
-- ============================================================================

-- Triggers añadidos
DROP TRIGGER IF EXISTS trg_top_pick_capture     ON public.analisis_partidos;
DROP TRIGGER IF EXISTS tpc_append_only_capture  ON public.top_pick_capture;
DROP TRIGGER IF EXISTS tpc_append_only_display  ON public.top_pick_display;

-- Vistas nuevas
DROP VIEW IF EXISTS public.v_top_pick_science_dataset;
DROP VIEW IF EXISTS public.v_top_pick_missing_emissions;
DROP VIEW IF EXISTS public.v_top_pick_capture_health;

-- Funciones nuevas
DROP FUNCTION IF EXISTS public.trg_capture_top_pick();
DROP FUNCTION IF EXISTS public.tpc_block_mutation();
DROP FUNCTION IF EXISTS public.capture_top_pick_universe(uuid, text, text);
DROP FUNCTION IF EXISTS public.assert_capture_contract(jsonb);
DROP FUNCTION IF EXISTS public.tpc_sha256(text);
DROP FUNCTION IF EXISTS public.tpc_norm_line(text);

-- Tablas nuevas (orden hijo->padre; no hay FKs a canónicos)
DROP TABLE IF EXISTS public.top_pick_display;
DROP TABLE IF EXISTS public.top_pick_settlement;
DROP TABLE IF EXISTS public.top_pick_capture_audit;
DROP TABLE IF EXISTS public.top_pick_capture;

-- pgcrypto NO se elimina (extensión compartida; su drop podría afectar otros objetos).
-- Sin DROP CASCADE. Objetos canónicos verificables intactos tras rollback.
