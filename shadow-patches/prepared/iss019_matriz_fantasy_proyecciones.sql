-- ISS-019 — MATRIZ CANÓNICA DE FANTASY (NFL PPR).  *** STAGED — NO APLICADO A PROD ***
-- Gate #14 + #18. Se aplica en el cutover.
--
-- IMPORTANTE: Fantasy produce PROYECCIONES DE PUNTOS (PPR), NO probabilidades de evento.
-- Es honesto y correcto: NO se fabrica ninguna probabilidad. La gobernanza de identidad
-- es la misma (espn_player_id canónico, 100% de nfl_jugadores lo tiene). MODEL_STATUS
-- se marca PROJECTIONS_ONLY.
--
-- Motor existente (real, maduro): fantasy_ranking(p_posicion,p_semana,p_temporada,p_tope,
-- p_min_partidos) → tabla con espn_player_id, jugador, posicion, equipo, proyeccion,
-- base_ppr, ppr_reg, ppr_reg_ult5, partidos_reg, cambio_equipo, rival, es_local, en_bye,
-- semana_bye, matchup, lugar_defensa, pts_concede_rival, factor, banderas.
-- Enriquecimiento de incertidumbre (piso/techo): lab_ff_project_v1 (projected_mean,
-- hist_low, hist_high, uncertainty, n_prev, cold_start, method, model_version) — por
-- jugador; se puede unir después. Aquí la matriz base sale de fantasy_ranking.
--
-- GAP DECLARADO (no fabricar): el scoring/roster de la liga del usuario NO está definido
-- en prod (lab_ff_league_config_v1 es shadow). Por eso VOR/valor-sobre-reemplazo asume
-- PPR estándar por defecto; se marca liga_config='DEFAULT_PPR' hasta que exista config real.

CREATE OR REPLACE FUNCTION public.v_prediccion_reto_fantasy(
  p_semana integer DEFAULT NULL, p_temporada integer DEFAULT NULL
) RETURNS TABLE (
  canonical_player_id text,
  jugador text,
  posicion text,
  equipo text,
  semana integer,
  temporada integer,
  proyeccion_mean numeric,
  piso numeric,
  techo numeric,
  incertidumbre numeric,
  base_ppr numeric,
  partidos_reg integer,
  rival text,
  es_local boolean,
  en_bye boolean,
  matchup text,
  factor_matchup numeric,
  cambio_equipo boolean,
  banderas text[],
  fuente_proyeccion text,
  model_status text,
  liga_config text,
  data_asof timestamptz
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public' AS $$
  SELECT r.espn_player_id,
         r.jugador, r.posicion, r.equipo,
         COALESCE(p_semana, r.lugar) * 0 + COALESCE(p_semana, 0) AS semana,  -- semana efectiva (0=actual por defecto del motor)
         COALESCE(p_temporada, extract(year from now())::int)   AS temporada,
         r.proyeccion,
         NULL::numeric AS piso,          -- enriquecer con lab_ff_project_v1.hist_low si se desea
         NULL::numeric AS techo,         -- lab_ff_project_v1.hist_high
         NULL::numeric AS incertidumbre, -- lab_ff_project_v1.uncertainty
         r.base_ppr,
         r.partidos_reg,
         r.rival, r.es_local, r.en_bye, r.matchup, r.factor, r.cambio_equipo, r.banderas,
         'fantasy_ranking'::text AS fuente_proyeccion,
         'PROJECTIONS_ONLY'::text AS model_status,
         'DEFAULT_PPR'::text AS liga_config,
         now() AS data_asof
  FROM public.fantasy_ranking(NULL, p_semana, p_temporada, 300, 3) r
  WHERE r.espn_player_id IS NOT NULL;
$$;

-- K/DEF viven en fantasy_ranking_k_def (nombre/equipo/puntos_pg) — no traen espn_player_id
-- uniforme; se conectan aparte cuando su identidad esté canonizada. NO se mezclan aquí
-- para no romper la clave canónica de jugador.
--
-- ROLLBACK: DROP FUNCTION public.v_prediccion_reto_fantasy(integer,integer);
--
-- FRONTEND (cutover): NflFantasy.tsx / FantasyRankingsTab / FantasyDraftTab consumen esta
-- matriz (proyecciones), rotuladas "PROYECCIÓN (PPR), no probabilidad". Nunca % de acierto.
