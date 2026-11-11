-- PROTOTIPO NO VERIFICADO — captura de divergencia libro-sharp vs DraftKings para el camino largo
-- del edge de fútbol (que el fútbol le gane al cierre, validado OOS).
--
-- HIPÓTESIS: DK (soft) va detrás del consenso sharp (Pinnacle); revierte hacia él al cierre =>
-- drift positivo predecible (CLV). Es la señal canónica de CLV en fútbol.
--
-- POR QUÉ PROTOTIPO: la fuente sharp es pinnapi (revendedor/scraper de Pinnacle, que cerró su API
-- oficial jul-2025). Es FRÁGIL: puede romperse sin aviso. Por eso esto NO alimenta ningún pick ni
-- récord — solo acumula el feature sharp. Si en ~6-8 semanas valida OOS en ventanas disjuntas, se
-- gradúa a una fuente robusta (ej. exchange Betfair, feed de paga). Si no, se descarta. Dinero/EV/Kelly FUERA.
--
-- Qué captura: congela el precio SHARP (Pinnacle) 1X2 a ~3.5h del saque (≈ momento de decisión) para
-- nuestros eventos de fútbol. DK-en-decisión, drift-al-cierre y lado-seleccionado ya los captura
-- v2.soccer_publication_market_evidence_v1. La validación OOS hace el join por espn_event_id:
--   div_pp = p_sharp[lado_seleccionado] - decision_market_p_novig   (DK)
--   y prueba si div_pp predice market_drift_samebook_pp en ventanas disjuntas.
--
-- Infra:
--   - tabla  public.reto_soccer_sharp_div_v1   (precio sharp congelado por evento)
--   - config public.reto_config_secreto_v1     (key pinnapi free-trial, bloqueada service-role)
--   - edge   capturar-sharp-div-futbol         (match por equipos+hora, no-vig, upsert; modo dry_run)
--   - cron   reto-sharp-div-futbol (jobid 610)  '*/30 * * * *'  body {"ventana_horas":3.5}

CREATE TABLE IF NOT EXISTS public.reto_soccer_sharp_div_v1 (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  espn_event_id     text NOT NULL,
  partido           text,
  kickoff           timestamptz,
  pinnapi_event_id  text,
  sharp_home_odds   numeric,
  sharp_draw_odds   numeric,
  sharp_away_odds   numeric,
  p_sharp_home      numeric,   -- no-vig
  p_sharp_draw      numeric,
  p_sharp_away      numeric,
  minutos_antes_kickoff integer,
  match_confianza   text,
  fuente_sharp      text NOT NULL DEFAULT 'pinnapi_pinnacle_prototipo',
  sharp_captured_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_sharp_div_evento UNIQUE (espn_event_id)
);
ALTER TABLE public.reto_soccer_sharp_div_v1 ENABLE ROW LEVEL SECURITY;

-- Config bloqueada (solo service-role). El valor del key se inserta aparte (no en migración).
CREATE TABLE IF NOT EXISTS public.reto_config_secreto_v1 (
  clave text PRIMARY KEY, valor text NOT NULL, nota text, updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.reto_config_secreto_v1 ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.reto_config_secreto_v1 FROM anon, authenticated;

-- Cron (idempotente):
-- select cron.schedule('reto-sharp-div-futbol','*/30 * * * *',
--   $$select net.http_post(
--       url := 'https://wpiztubmmmzclhlprgpd.supabase.co/functions/v1/capturar-sharp-div-futbol',
--       headers := jsonb_build_object('Content-Type','application/json','Authorization','Bearer '||public.sk()),
--       body := '{"ventana_horas":3.5}'::jsonb, timeout_milliseconds := 25000);$$);
