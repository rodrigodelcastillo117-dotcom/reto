-- ============================================================================
-- Odds de ESPN + CLV del sistema reto — wpiztubmmmzclhlprgpd — 2026-10-20
-- Ver ODDS_ESPN_Y_CLV_RETO_V1.md. Funciones completas en las migraciones:
--   reto_odds_espn_ingesta, reto_odds_pedir_scoreboard_pordia,
--   gate_v2_con_odds_espn, v_reto_clv_espn.
-- Endpoint ESPN: sports.core.api.espn.com/v2/sports/{liga}/events/{eid}/competitions/{cid}/odds
-- (trae open/close/current; NBA/NHL/MLB/NFL sí, tenis no).
-- ============================================================================

-- Tabla destino (open/close/current de ML y total por evento+proveedor)
create table if not exists public.reto_odds_espn_v1 (
  espn_event_id text not null, deporte text not null, provider text not null,
  ml_home_open numeric, ml_away_open numeric, ml_home_close numeric, ml_away_close numeric,
  ml_home_cur numeric, ml_away_cur numeric,
  total_open numeric, total_close numeric, total_cur numeric,
  over_open numeric, under_open numeric, over_close numeric, under_close numeric,
  actualizado timestamptz not null default now(),
  primary key (espn_event_id, provider)
);

-- Cron de captura (cada 20 min): parsea ciclo previo, pide odds, pide scoreboards.
select cron.schedule('reto-odds-espn', '*/20 * * * *', $$
  select public.reto_odds_parse_odds(200);
  select public.reto_odds_parse_sb_pedir_odds();
  select public.reto_odds_pedir_scoreboard();
$$);

-- CLV del sistema reto (GANADOR NBA/NHL/MLB/NFL): prob implícita de-vigada del
-- lado elegido, apertura vs cierre. clv_pp>0 sostenido = el modelo gana al cierre.
--   (definición completa en migración v_reto_clv_espn)
-- select deporte, round(avg(clv_pp),2) clv_medio, count(*) n, count(acierto) resueltos
-- from public.v_reto_clv_espn_v1 where clv_pp is not null group by deporte;

-- Gate v2: v_reto_mercado_gate_v1 ahora marca NBA/NHL/MLB/NFL como "CLV MEDIBLE
-- vía ESPN" y tenis como "SIN CUOTAS — ESPN no publica odds de tenis".
