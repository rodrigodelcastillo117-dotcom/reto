-- ============================================================================
-- iss033 — BUILDER TEMPORALMENTE REPRODUCIBLE + CONTRATO CANÓNICO (BLOQUE 5/6)
-- STAGED · NO APLICAR · NO PROD MUTATION · corrige AUDIT_NO_PASS comment 5606845587
-- ============================================================================
-- PROBLEMA (verificado en PROD, v2.build_soccer_prediction_v2 + v_futpro_v2):
--  - temporal_safe = literal true.
--  - features desde el AGREGADO MÓVIL v_goles_equipo_futbol (contra now()).
--  - data_asof = greatest(ultimo_partido) = fecha deportiva, no disponibilidad.
--  - sample floor >=8, model/version/feature_version/calibration HARDCODEADOS.
--  - INNER JOIN liga_alias + competition_catalog enabled=true -> los no soportados
--    DESAPARECEN del universo.
--  - v_futpro_v2 RE-UNE el agregado actual (home_gf_pg...) -> los inputs mostrados
--    cambian DESPUÉS de la predicción.
-- PRUEBA (Barcelona LaLiga, decision 2026-05-01): as-of home GF=2.774 (max fuente
--  2026-04-22 < decision) vs móvil actual=2.816 (ultimo_partido 2026-09-06, incluye
--  4 partidos POSTERIORES a la decisión). El móvil NO es reproducible.
--
-- FIX (staged): features AS OF decision_time desde partidos FINAL con fecha<decision,
--  temporal_safe calculado de verdad, feature snapshot persistido, thresholds/versión
--  registry-driven, agenda como universo (LEFT JOIN), contrato canónico 1 fila/evento
--  con btts_yes+btts_no explícitos y sin re-unir el agregado móvil.
-- ============================================================================

-- ── 1) Config registry-driven (elimina literales del builder) ────────────────
create table if not exists v2.model_config (
  sport text, model_name text, model_version text, feature_version text,
  calibration_status text, sample_floor int, window_days int, publish_authorized boolean,
  primary key (sport, model_version)
);
insert into v2.model_config values
  ('soccer','reto_dc_v2','dc-2026.09.1','goal_rates_same_comp_asof_v2','UNVALIDATED',8,540,true)
on conflict (sport,model_version) do update set
  feature_version=excluded.feature_version, sample_floor=excluded.sample_floor,
  window_days=excluded.window_days, publish_authorized=excluded.publish_authorized;

-- ── 2) Features AS OF decision_time (reproducible, FINAL-only, fecha<decision) ──
-- Mirror del split de producción: local del equipo local, visitante del visitante.
create or replace function v2.fn_soccer_features_asof(
  p_home_id text, p_away_id text, p_liga_id int, p_decision_time timestamptz, p_window_days int default 540
) returns table(
  home_gf numeric, home_gc numeric, away_gf numeric, away_gc numeric,
  sample_home int, sample_away int, feature_data_asof timestamptz, max_source_event_time timestamptz
) language sql stable as $$
  with h as (  -- partidos del LOCAL como local, FINAL, estrictamente antes de decision
    select avg(home_score) gf, avg(away_score) gc, count(*) n, max(fecha) mx
    from public.historico_partidos_espn
    where home_espn_id=p_home_id and liga_id=p_liga_id and home_score is not null
      and fecha < p_decision_time and fecha >= p_decision_time - make_interval(days=>p_window_days)
  ),
  a as (  -- partidos del VISITANTE como visitante
    select avg(away_score) gf, avg(home_score) gc, count(*) n, max(fecha) mx
    from public.historico_partidos_espn
    where away_espn_id=p_away_id and liga_id=p_liga_id and home_score is not null
      and fecha < p_decision_time and fecha >= p_decision_time - make_interval(days=>p_window_days)
  )
  select round(h.gf,4),round(h.gc,4),round(a.gf,4),round(a.gc,4),
         h.n::int, a.n::int, greatest(h.mx,a.mx), greatest(h.mx,a.mx)
  from h,a;
$$;

-- ── 3) Snapshot persistido para reproducir cada P_RETO (point 5) ─────────────
create table if not exists v2.feature_snapshot (
  feature_snapshot_id uuid primary key default gen_random_uuid(),
  espn_event_id text, decision_time timestamptz,
  home_gf numeric, home_gc numeric, away_gf numeric, away_gc numeric,
  sample_home int, sample_away int, feature_data_asof timestamptz, max_source_event_time timestamptz,
  feature_version text, created_at timestamptz default now(),
  unique (espn_event_id, decision_time, feature_version)
);

-- ── 4) Builder reproducible (decision_time explícito; sin now() como autoridad) ─
-- Diferencias clave vs producción: features as-of, temporal_safe calculado, config
-- registry-driven, agenda LEFT JOIN (universo), snapshot persistido.
create or replace function v2.build_soccer_prediction_v2_staged(p_decision_time timestamptz)
returns integer language plpgsql as $function$
declare n int; cfg record;
begin
  select * into cfg from v2.model_config where sport='soccer' and model_version='dc-2026.09.1';
  with agenda as (  -- AGENDA = UNIVERSO (LEFT JOIN al modelo/catálogo; nada desaparece)
    select distinct on (a.espn_event_id) a.espn_event_id, a.liga_id, a.liga_nombre,
           a.home_nombre, a.away_nombre, a.fecha kickoff,
           a.home_espn_id, a.away_espn_id
    from public.agenda_espn a
    where a.deporte='soccer' and a.fecha > p_decision_time
    order by a.espn_event_id, a.fecha
  ),
  mapped as (
    select ag.*, la.competition_id,
           (r.approved is true) reg_ok
    from agenda ag
    left join v2.liga_alias la on la.liga_source = ag.liga_nombre
    left join v2.competition_catalog c on c.competition_id=la.competition_id and c.enabled=true
    left join v2.model_registry r on r.sport='soccer' and r.model_name=cfg.model_name
         and r.model_version=cfg.model_version and r.liga_id=ag.liga_id
  ),
  feats as (
    select m.*, f.home_gf,f.home_gc,f.away_gf,f.away_gc,f.sample_home,f.sample_away,
           f.feature_data_asof, f.max_source_event_time,
           o.over_line,o.over_odds,o.under_odds,o.home_ml,o.draw_ml,o.away_ml,o.bookmaker,o.snapshot_at
    from mapped m
    left join lateral v2.fn_soccer_features_asof(m.home_espn_id,m.away_espn_id,m.liga_id,p_decision_time,cfg.window_days) f on true
    left join lateral (select * from v2.fn_real_total_line(m.espn_event_id,p_decision_time)) o on true
  ),
  calc as (
    select fe.*,
      -- temporal_safe CALCULADO (nunca literal true)
      (fe.max_source_event_time is not null and fe.max_source_event_time <= p_decision_time) temporal_safe_calc,
      v2.fn_score_dist(fe.home_gf,fe.home_gc,fe.away_gf,fe.away_gc,
                       lg.media_goles_local, lg.media_goles_visita, fe.over_line) d
    from feats fe left join public.v_liga_promedios_futbol lg on lg.liga_id=fe.liga_id
  )
  insert into v2.soccer_prediction_v2_staged
    (espn_event_id, competition_id, home_team, away_team, kickoff, decision_time,
     feature_data_asof, max_source_event_time, sample_home, sample_away, temporal_safe,
     feature_version, model_version, calibration_status,
     p_home,p_draw,p_away, btts_yes,btts_no, over_line,p_over,p_under, line_source,line_asof,
     model_status, model_status_reason, provenance)
  select c.espn_event_id, c.competition_id, c.home_nombre, c.away_nombre, c.kickoff, p_decision_time,
     c.feature_data_asof, c.max_source_event_time, c.sample_home, c.sample_away, c.temporal_safe_calc,
     cfg.feature_version, cfg.model_version, cfg.calibration_status,
     case when pub.publish then (c.d->>'p_home')::numeric end,
     case when pub.publish then (c.d->>'p_draw')::numeric end,
     case when pub.publish then (c.d->>'p_away')::numeric end,
     case when pub.publish then (c.d->>'btts_yes')::numeric end,
     case when pub.publish then (c.d->>'btts_no')::numeric end,           -- btts_no EXPLÍCITO
     c.over_line,
     case when pub.publish and c.over_line is not null then (c.d->>'p_over')::numeric end,
     case when pub.publish and c.over_line is not null then (c.d->>'p_under')::numeric end,
     case when c.over_line is not null then 'v_momios_confiables:'||coalesce(c.bookmaker,'?') end,
     c.snapshot_at,
     case when pub.publish then 'READY_UNVALIDATED'
          when c.competition_id is null then 'NO_MODEL'      -- unsupported/unmapped: visible, P=NULL
          else 'DATA_INCOMPLETE' end,
     case when pub.publish then 'DC V2 as-of decision_time desde tasas FINAL de la misma competencia'
          when c.competition_id is null then 'Competencia no mapeada/soportada: evento visible sin P_RETO'
          when not c.reg_ok then 'Competencia no aprobada para el modelo'
          when c.sample_home is null or c.sample_away is null then 'Sin tasas de ambos equipos EN ESTA competencia'
          when c.sample_home < cfg.sample_floor or c.sample_away < cfg.sample_floor then 'Muestra insuficiente (<'||cfg.sample_floor||')'
          when not c.temporal_safe_calc then 'Fuga temporal: features posteriores a decision_time'
          when c.d is null then 'El modelo no pudo estimar goles'
          else 'Datos insuficientes' end,
     jsonb_build_object('engine','dc_goal_rates_asof','event_liga_id',c.liga_id,
        'competition_approved',c.reg_ok,'feature_data_asof',c.feature_data_asof,
        'temporal_safe',c.temporal_safe_calc,'odds_is_context_not_preto',true)
  from calc c, cfg,
       lateral (select (c.reg_ok and c.sample_home is not null and c.sample_away is not null
                        and c.sample_home>=cfg.sample_floor and c.sample_away>=cfg.sample_floor
                        and c.d is not null and c.temporal_safe_calc) as publish) pub;
  get diagnostics n = row_count;
  return n;
end $function$;

-- ── 5) Contrato canónico 1 fila/evento (btts_yes+btts_no explícitos; sin re-unir agregado móvil)
-- (point 8/9) Se define sobre soccer_prediction_v2_staged; el frontend consume ESTO.
-- create view v2.v_soccer_canonical as
--   select espn_event_id canonical_event_id, espn_event_id provider_event_id, competition_id,
--          home_team, away_team, kickoff, decision_time, model_version model_name, model_version,
--          model_status, p_home p_reto_home, p_draw p_reto_draw, p_away p_reto_away,
--          btts_yes, btts_no,                       -- AMBOS explícitos del MISMO snapshot
--          over_line total_line, p_over over_prob, p_under under_prob, line_source, line_asof,
--          model_status_reason missing_reason, provenance
--   from v2.soccer_prediction_v2_staged;   -- NO se une v_goles_equipo_futbol (inputs congelados en snapshot)
