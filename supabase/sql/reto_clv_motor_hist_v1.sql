-- Persistencia del CLV motor (EU) — para que la prueba de rentabilidad ACUMULE en vez de ser
-- una ventana rodante de ~3 semanas. v_reto_clv_motor_v1 es una vista viva sobre picks × cierre
-- ESPN (reto_odds_espn_v1), cuya retención corta hace que eventos viejos pierdan su cierre y caigan
-- de la vista (quedaba fija en ~110). Congelamos cada evento una vez con kickoff pasado (cierre ya
-- final). Append-only; dinero/EV/Kelly fuera; cero cuota OddsAPI.
-- El tablero (v_reto_tablero_validacion_v1) lee hist ∪ vista-viva-reciente, deduplicado por evento.
-- Cron: reto-clv-motor-congelar (jobid 609), '17 */4 * * *'  -> select reto_clv_motor_snapshot_v1();

CREATE TABLE IF NOT EXISTS public.reto_clv_motor_hist_v1 (
  espn_event_id     text PRIMARY KEY,
  deporte           text NOT NULL,
  partido           text,
  kickoff           timestamptz,
  pick_titulo       text,
  prob_entrada_pct  numeric,
  prob_cierre_pct   numeric,
  clv_pp            numeric,
  le_gano_al_cierre boolean,
  snapshotted_at    timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.reto_clv_motor_hist_v1 ENABLE ROW LEVEL SECURITY;
-- Sin policy: acceso solo vía función SECURITY DEFINER (escritura) y vista dueño (lectura). No anon directo.

CREATE OR REPLACE FUNCTION public.reto_clv_motor_snapshot_v1()
RETURNS integer
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n integer;
BEGIN
  INSERT INTO public.reto_clv_motor_hist_v1
    (espn_event_id, deporte, partido, kickoff, pick_titulo, prob_entrada_pct, prob_cierre_pct, clv_pp, le_gano_al_cierre)
  SELECT espn_event_id, deporte, partido, kickoff, pick_titulo, prob_entrada_pct, prob_cierre_pct, clv_pp, le_gano_al_cierre
  FROM public.v_reto_clv_motor_v1
  WHERE clv_pp IS NOT NULL AND kickoff < now()   -- kickoff pasado => cierre final
  ON CONFLICT (espn_event_id) DO NOTHING;         -- idempotente: no re-escribe un evento
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n;
END $$;

REVOKE ALL ON FUNCTION public.reto_clv_motor_snapshot_v1() FROM public, anon, authenticated;

-- Cron (idempotente): congela eventos nuevos cada 4h.
-- select cron.schedule('reto-clv-motor-congelar', '17 */4 * * *', $$select public.reto_clv_motor_snapshot_v1();$$);
