-- ============================================================================
-- ROLLBACK TOP_PICK_FORWARD_CAPTURE_V1 v4 (SHADOW / solo LAB branch)
-- Elimina SOLO objetos nuevos de v4. Sin CASCADE a objetos canónicos.
-- v_pick_canonico / economic_* / oraculo_picks_tracking / analisis_partidos y sus triggers
-- existentes quedan INTACTOS. No revierte P/EV/es_pick/stake.
-- (DROP TABLE no dispara los triggers de fila append-only; el rollback es limpio.)
-- ============================================================================

-- Triggers añadidos en analisis_partidos
DROP TRIGGER IF EXISTS trg_a_emission_ledger  ON public.analisis_partidos;
DROP TRIGGER IF EXISTS trg_b_top_pick_capture ON public.analisis_partidos;

-- Triggers append-only
DROP TRIGGER IF EXISTS tpc_ao_capture    ON public.top_pick_capture;
DROP TRIGGER IF EXISTS tpc_ao_capture_t  ON public.top_pick_capture;
DROP TRIGGER IF EXISTS tpc_ao_display    ON public.top_pick_display;
DROP TRIGGER IF EXISTS tpc_ao_ledger     ON public.prediction_emission_ledger;
DROP TRIGGER IF EXISTS tpc_ao_ledger_t   ON public.prediction_emission_ledger;

-- Vistas
DROP VIEW IF EXISTS public.v_top_pick_science_dataset;
DROP VIEW IF EXISTS public.v_top_pick_capture_health;
DROP VIEW IF EXISTS public.v_top_pick_unledgered_analysis;
DROP VIEW IF EXISTS public.v_emission_ledger_reconciliation;

-- Funciones
DROP FUNCTION IF EXISTS public.trg_emission_ledger();
DROP FUNCTION IF EXISTS public.trg_capture_top_pick();
DROP FUNCTION IF EXISTS public.capture_top_pick_universe(uuid, text, text);
DROP FUNCTION IF EXISTS public.assert_capture_contract(jsonb);
DROP FUNCTION IF EXISTS public.tpc_admin_correct(uuid, text, jsonb);
DROP FUNCTION IF EXISTS public.tpc_block_row_mutation();
DROP FUNCTION IF EXISTS public.tpc_block_truncate();
DROP FUNCTION IF EXISTS public.tpc_row_hash(text, text, text, numeric, numeric, numeric, numeric, text);
DROP FUNCTION IF EXISTS public.tpc_strip_label(text);
DROP FUNCTION IF EXISTS public.tpc_norm_line(text);
DROP FUNCTION IF EXISTS public.tpc_sha256(text);

-- Tablas (hijo -> padre; top_pick_capture referencia al ledger)
DROP TABLE IF EXISTS public.top_pick_capture_correction;
DROP TABLE IF EXISTS public.top_pick_display;
DROP TABLE IF EXISTS public.top_pick_settlement;
DROP TABLE IF EXISTS public.top_pick_capture_audit;
DROP TABLE IF EXISTS public.top_pick_capture;
DROP TABLE IF EXISTS public.prediction_emission_ledger;

-- Rol admin (solo si no lo usa nada más). Comentar si el rol es compartido.
DROP ROLE IF EXISTS tpc_admin;

-- pgcrypto NO se elimina (extensión compartida). Sin DROP CASCADE. Canónicos intactos.
