-- ROLLBACK TOP_PICK_FORWARD_CAPTURE_V1 v2 (seguro: objetos nuevos, sin dependientes canónicos)
DROP TRIGGER IF EXISTS trg_top_pick_capture ON public.analisis_partidos;
DROP FUNCTION IF EXISTS public.trg_capture_top_pick();
DROP FUNCTION IF EXISTS public.capture_top_pick_universe(text, text, uuid, text);
DROP FUNCTION IF EXISTS public.assert_capture_contract();
DROP TABLE IF EXISTS public.top_pick_display;
DROP TABLE IF EXISTS public.top_pick_settlement;
DROP TABLE IF EXISTS public.top_pick_capture_audit;
DROP TABLE IF EXISTS public.top_pick_capture;
-- Sin DROP CASCADE sobre objetos existentes. v_pick_canonico/economic_*/oraculo_picks_tracking/analisis_partidos intactos.
