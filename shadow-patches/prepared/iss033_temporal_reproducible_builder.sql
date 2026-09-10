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
-- Append-only (AUDIT 5611083879 pt3): NO DO UPDATE — cambiar params bajo el MISMO
-- model_version mutaría silenciosamente el belief histórico. Un cambio de gobernanza
-- exige un model_version NUEVO. Re-seed idéntico = no-op.
insert into v2.model_config values
  ('soccer','reto_dc_v2','dc-2026.09.1','goal_rates_same_comp_asof_v2','UNVALIDATED',8,540,true)
on conflict (sport,model_version) do nothing;
-- Guarda fail-on-drift: si alguien intenta UPDATE de params bajo un model_version sellado,
-- se aborta (la identidad versionada no cambia belief en-place).
-- AUDIT 5611572904 pt1: WHOLE-ROW inmutable (antes sólo 3 columnas; model_name/
-- calibration_status/publish_authorized quedaban editables in-place => drift de gobernanza).
create or replace function v2.fn_model_config_immutable() returns trigger language plpgsql as $$
begin
  if to_jsonb(new) is distinct from to_jsonb(old) then
    raise exception 'MODEL_CONFIG_DRIFT: (%,%) es inmutable (whole-row); usa un model_version nuevo',
      new.sport, new.model_version;
  end if;
  return new;
end $$;
drop trigger if exists trg_model_config_immutable on v2.model_config;
create trigger trg_model_config_immutable before update on v2.model_config
  for each row execute function v2.fn_model_config_immutable();

-- ── 2) Features AS OF decision_time (reproducible, FINAL-only, fecha<decision) ──
-- Mirror del split de producción: local del equipo local, visitante del visitante.
-- HARDENING (audit hostil iss033, 2026-09-09):
--  F3: p_exclude_event_id excluye EXPLÍCITAMENTE el evento target aunque por datos
--      defectuosos aparezca en histórico con fecha anterior (§6.C).
--  F5: historico.fecha ES timestamptz (kickoff real) => fecha<decision es comparación
--      de timestamp, no de día. Para PRODUCCIÓN HACIA ADELANTE, además se filtra por
--      disponibilidad (cargado_at<=decision) cuando p_enforce_availability=true; para
--      REPLAY histórico se deja false porque cargado_at es tiempo de backfill (bulk,
--      posterior a decisiones históricas) y no representa la disponibilidad de época.
--      max_source_event_time sigue siendo el kickoff (fecha) máximo usado.
create or replace function v2.fn_soccer_features_asof(
  p_home_id text, p_away_id text, p_liga_id int, p_decision_time timestamptz,
  p_window_days int default 540, p_exclude_event_id text default null,
  p_enforce_availability boolean default false
) returns table(
  home_gf numeric, home_gc numeric, away_gf numeric, away_gc numeric,
  sample_home int, sample_away int, feature_data_asof timestamptz, max_source_event_time timestamptz
) language sql stable as $$
  with h as (  -- partidos del LOCAL como local, FINAL, estrictamente antes de decision
    select avg(home_score) gf, avg(away_score) gc, count(*) n, max(fecha) mx
    from public.historico_partidos_espn
    where home_espn_id=p_home_id and liga_id=p_liga_id and home_score is not null
      and fecha < p_decision_time and fecha >= p_decision_time - make_interval(days=>p_window_days)
      and espn_event_id is distinct from p_exclude_event_id                 -- F3
      and (not p_enforce_availability or cargado_at <= p_decision_time)     -- F5
  ),
  a as (  -- partidos del VISITANTE como visitante
    select avg(away_score) gf, avg(home_score) gc, count(*) n, max(fecha) mx
    from public.historico_partidos_espn
    where away_espn_id=p_away_id and liga_id=p_liga_id and home_score is not null
      and fecha < p_decision_time and fecha >= p_decision_time - make_interval(days=>p_window_days)
      and espn_event_id is distinct from p_exclude_event_id                 -- F3
      and (not p_enforce_availability or cargado_at <= p_decision_time)     -- F5
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

-- ── 3b) Tabla destino del builder (F2: antes se insertaba sin crearla) ────────
-- Contrato canónico 1 fila/evento. Sin defaults dinámicos; el builder llena todo.
create table if not exists v2.soccer_prediction_v2_staged (
  espn_event_id text, competition_id int, home_team text, away_team text,
  kickoff timestamptz, decision_time timestamptz,
  feature_data_asof timestamptz, max_source_event_time timestamptz,
  sample_home int, sample_away int, temporal_safe boolean,
  feature_version text, model_version text, calibration_status text,
  p_home numeric, p_draw numeric, p_away numeric, btts_yes numeric, btts_no numeric,
  over_line numeric, p_over numeric, p_under numeric, line_source text, line_asof timestamptz,
  model_status text, model_status_reason text, provenance jsonb,
  competition_mapping_version text,          -- §20: mapping_version CONGELADO en la fila (AUDIT 5611083879 pt1)
  availability_verified boolean,             -- pt2: ¿se exigió cargado_at<=decision? (no-leak de disponibilidad)
  score_dist jsonb,                          -- 5619542059-3: matriz conjunta COMPLETA persistida (única fuente)
  top_scores jsonb,                          -- 5619542059-5: top-k canónico ordenado por prob (no dist.slice)
  feature_snapshot_id uuid, built_at timestamptz default now(),
  primary key (espn_event_id, decision_time, model_version)
);
-- (para tablas ya creadas en branch)
alter table v2.soccer_prediction_v2_staged add column if not exists competition_mapping_version text;
alter table v2.soccer_prediction_v2_staged add column if not exists availability_verified boolean;
alter table v2.soccer_prediction_v2_staged add column if not exists score_dist jsonb;
alter table v2.soccer_prediction_v2_staged add column if not exists top_scores jsonb;

-- pt3: feature_snapshot inmutable fail-on-drift. Re-run idéntico = no-op; cambio de
-- features bajo la MISMA (event,decision,feature_version) => RAISE (no reescribe belief).
create or replace function v2.fn_feature_snapshot_immutable() returns trigger language plpgsql as $$
begin
  if row(new.home_gf,new.home_gc,new.away_gf,new.away_gc,new.sample_home,new.sample_away,
         new.feature_data_asof,new.max_source_event_time) is distinct from
     row(old.home_gf,old.home_gc,old.away_gf,old.away_gc,old.sample_home,old.sample_away,
         old.feature_data_asof,old.max_source_event_time) then
    raise exception 'FEATURE_SNAPSHOT_DRIFT: (%,%,%) ya sellado con features distintas; usa un feature_version nuevo',
      new.espn_event_id, new.decision_time, new.feature_version;
  end if;
  return new;
end $$;
drop trigger if exists trg_feature_snapshot_immutable on v2.feature_snapshot;
create trigger trg_feature_snapshot_immutable before update on v2.feature_snapshot
  for each row execute function v2.fn_feature_snapshot_immutable();

-- ── 4) Builder reproducible (decision_time explícito; sin now() como autoridad) ─
-- Diferencias clave vs producción: features as-of, temporal_safe calculado, config
-- registry-driven, agenda LEFT JOIN (universo), snapshot persistido.
-- AUDIT 5611083879: p_enforce_availability default TRUE (forward-safe); p_mapping_version
-- permite replay explícito. La mapping_version se CAPTURA una vez (v_map) y se persiste.
create or replace function v2.build_soccer_prediction_v2_staged(
  p_decision_time timestamptz,
  p_enforce_availability boolean default true,
  p_mapping_version text default null
) returns integer language plpgsql as $function$
declare n int; cfg record; v_map text;
begin
  select * into cfg from v2.model_config where sport='soccer' and model_version='dc-2026.09.1';
  -- pt1: congela UNA mapping_version para todo el build (no re-lee el puntero activo por fila).
  v_map := coalesce(p_mapping_version, v2.fn_competition_active_mapping());
  with agenda as (  -- AGENDA = UNIVERSO (LEFT JOIN al modelo/catálogo; nada desaparece)
    select distinct on (a.espn_event_id) a.espn_event_id, a.liga_id, a.liga_nombre,
           a.home_nombre, a.away_nombre, a.fecha kickoff,
           a.home_espn_id, a.away_espn_id
    from public.agenda_espn a
    where a.deporte='soccer' and a.fecha > p_decision_time
    order by a.espn_event_id, a.fecha
  ),
  mapped as (
    -- §20 (iss039): identidad por PROVIDER-ID numérico con la mapping_version CONGELADA (v_map).
    -- AUDIT 5611572904 pt2: registry y features siguen keyed por ag.liga_id (provider).
    -- Para que el mapping sea AUTORIDAD END-TO-END, el canonical competition_id resuelto
    -- debe COINCIDIR con la identidad provider que gobierna registry/features (ag.liga_id).
    -- Si un remap hace competition_id != ag.liga_id, la aprobación/priores/features serían de
    -- OTRA liga => end_to_end=false => fail-close (NO_MODEL), nunca publicar id canónico
    -- servido por registry/features de otra identidad.
    select ag.*, rc.competition_id,
           (r.approved is true) reg_ok,
           (rc.competition_id is not null and rc.competition_id = ag.liga_id) as end_to_end
    from agenda ag
    left join lateral v2.fn_resolve_competition('espn', ag.liga_id, v_map) rc on true
    left join v2.model_registry r on r.sport='soccer' and r.model_name=cfg.model_name
         and r.model_version=cfg.model_version and r.liga_id=ag.liga_id
  ),
  feats as (
    select m.*, f.home_gf,f.home_gc,f.away_gf,f.away_gc,f.sample_home,f.sample_away,
           f.feature_data_asof, f.max_source_event_time,
           o.provider_total_line as over_line, o.over_odds, o.under_odds,
           o.provider as bookmaker, o.line_asof as snapshot_at
    from mapped m
    -- pt2: pasa p_enforce_availability (exige cargado_at<=decision cuando true).
    left join lateral v2.fn_soccer_features_asof(
        m.home_espn_id,m.away_espn_id,m.liga_id,p_decision_time,cfg.window_days,
        m.espn_event_id, p_enforce_availability) f on true
    left join lateral (select * from v2.fn_real_total_line(m.espn_event_id,p_decision_time)) o on true
  ),
  calc as (
    select fe.*,
      -- pt2: temporal_safe SÓLO si (kickoff<=decision) Y se verificó disponibilidad de época.
      -- Un replay sin enforce (availability_verified=false) NO reclama temporal_safe.
      (fe.max_source_event_time is not null and fe.max_source_event_time <= p_decision_time
         and p_enforce_availability) temporal_safe_calc,
      v2.fn_score_dist(fe.home_gf,fe.home_gc,fe.away_gf,fe.away_gc,
                       lg.media_goles_local, lg.media_goles_visita, fe.over_line) d
    from feats fe left join public.v_liga_promedios_futbol lg on lg.liga_id=fe.liga_id
  ),
  -- F1: PERSISTE el snapshot de features (antes la tabla existía pero nunca se llenaba).
  -- Data-modifying CTE: escribe una fila por evento con features y devuelve su id.
  snap as (
    insert into v2.feature_snapshot
      (espn_event_id, decision_time, home_gf, home_gc, away_gf, away_gc,
       sample_home, sample_away, feature_data_asof, max_source_event_time, feature_version)
    select c.espn_event_id, p_decision_time, c.home_gf, c.home_gc, c.away_gf, c.away_gc,
       c.sample_home, c.sample_away, c.feature_data_asof, c.max_source_event_time, cfg.feature_version
    from calc c
    where c.sample_home is not null and c.sample_away is not null
    on conflict (espn_event_id, decision_time, feature_version) do update
      set home_gf=excluded.home_gf, home_gc=excluded.home_gc,
          away_gf=excluded.away_gf, away_gc=excluded.away_gc,
          sample_home=excluded.sample_home, sample_away=excluded.sample_away,
          feature_data_asof=excluded.feature_data_asof,
          max_source_event_time=excluded.max_source_event_time
    returning espn_event_id, feature_snapshot_id
  )
  insert into v2.soccer_prediction_v2_staged
    (espn_event_id, competition_id, home_team, away_team, kickoff, decision_time,
     feature_data_asof, max_source_event_time, sample_home, sample_away, temporal_safe,
     feature_version, model_version, calibration_status,
     p_home,p_draw,p_away, btts_yes,btts_no, over_line,p_over,p_under, line_source,line_asof,
     model_status, model_status_reason, provenance,
     competition_mapping_version, availability_verified, score_dist, top_scores, feature_snapshot_id)
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
          when not c.end_to_end then 'NO_MODEL'              -- remap no end-to-end: fail-close
          else 'DATA_INCOMPLETE' end,
     case when pub.publish then 'DC V2 as-of decision_time desde tasas FINAL de la misma competencia'
          when c.competition_id is null then 'Competencia no mapeada/soportada (provider-id): evento visible sin P_RETO'
          when not c.end_to_end then 'MAPPING_NOT_END_TO_END: canonical competition_id ('||c.competition_id||') != identidad provider (liga_id '||c.liga_id||') que gobierna registry/features; fail-close'
          when not c.reg_ok then 'Competencia no aprobada para el modelo'
          when c.sample_home is null or c.sample_away is null then 'Sin tasas de ambos equipos EN ESTA competencia'
          when c.sample_home < cfg.sample_floor or c.sample_away < cfg.sample_floor then 'Muestra insuficiente (<'||cfg.sample_floor||')'
          when not p_enforce_availability then 'REPLAY_AVAILABILITY_UNVERIFIED: disponibilidad de época no verificada; no se reclama temporal_safe'
          when c.max_source_event_time is not null and c.max_source_event_time > p_decision_time then 'Fuga temporal: features posteriores a decision_time'
          when c.d is null then 'El modelo no pudo estimar goles'
          else 'Datos insuficientes' end,
     jsonb_build_object('engine','dc_goal_rates_asof','event_liga_id',c.liga_id,
        'competition_approved',c.reg_ok,'feature_data_asof',c.feature_data_asof,
        'temporal_safe',c.temporal_safe_calc,'odds_is_context_not_preto',true,
        'competition_mapping_version',v_map,'availability_verified',p_enforce_availability,
        'availability_note', case when p_enforce_availability then 'ENFORCED_cargado_at<=decision'
                                  else 'REPLAY_AVAILABILITY_UNVERIFIED' end),
     v_map, p_enforce_availability,
     case when pub.publish then (c.d->'dist') end,          -- 5619542059-3: matriz persistida (misma fuente)
     case when pub.publish then (c.d->'top_scores') end,    -- 5619542059-5: top-k canónico persistido
     s.feature_snapshot_id
  -- F7: 'cfg' es una variable record de plpgsql; sus campos se usan como escalares.
  -- NO puede ir en el FROM como si fuera una tabla (antes: 'from calc c, cfg' => error).
  from calc c
       left join snap s on s.espn_event_id = c.espn_event_id
       cross join lateral (select (c.reg_ok and c.end_to_end and c.sample_home is not null and c.sample_away is not null
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
