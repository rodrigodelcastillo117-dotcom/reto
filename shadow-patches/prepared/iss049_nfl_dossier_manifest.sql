-- ============================================================================
-- iss049 — NFL "Ver análisis completo" DOSSIER MANIFEST · PARITY WITH SOCCER · STAGED
-- ============================================================================
-- issue #4 comment 5620196530 — SAME shell/contract as soccer (iss030), DIFFERENT
-- brain per sport. This mirrors EXACTLY the return contract of
-- v2.fn_soccer_dossier_manifest (iss030 v3): same column names/types/order.
--
-- NFL BRAIN CONTRACT (NFL_BRAIN_INVENTORY.md + issue #4): NFL has NO independent
-- own-probability model today (nfl_predecir stamps es_modelo=false,
-- nota_modelo='NFL no tiene modelo independiente de probabilidad'). Therefore:
--   * modelo_p_reto row => role='NO_OWN_MODEL', available=false, effective_value=NULL,
--     used_in_p_reto=false. P_RETO IS NULL. The sportsbook no-vig price
--     (nfl_partidos.p_home/p_away) and ESPN-FPI are NEVER labelled P_RETO.
--   * EVERY other source is MARKET or CONTEXT, never MODEL_ACTIVE, never P_RETO.
--     used_in_p_reto is HARD-WIRED false for every NFL row (there is no own model to
--     feed). effective_value / feature_snapshot_id / feature_version /
--     max_source_event_time are always NULL (no own-model feature snapshot exists).
--   * motor_nfl (parallel/legacy uncalibrated engine) is QUARANTINED — surfaced only
--     as an explicitly-excluded marker row, never as a source that feeds the dossier.
--
-- HARD temporal rule (identical to soccer): a source is valid_prematch ONLY if
--   data_asof <= decision_time. Sources with no defensible per-row as_of
--   (weather/roof/venue at a neutral site, h2h, bye/rest, standings, record,
--   the stale mv_fuerza_nfl_espn matview) => role AVAILABLE_NOT_USED /
--   freshness NO_ASOF, never an invented as_of, never used. A capture strictly AFTER
--   decision_time => post_decision_capture=true, not counted as prematch coverage,
--   and the valid earlier capture is never deleted.
--
-- decision_time authority = the immutable per-run capture nfl_predicciones_historial
--   .capturado_at (analogue of soccer's staged prediction decision_time), never the
--   kickoff (nfl_predicciones_historial.saque / nfl_partidos.fecha). No real capture
--   and no explicit argument => fail-closed NO_DECISION_TIME (exactly like soccer).
--
-- NEUTRAL-SITE SAFETY (event 401872657, SF 49ers @ LA Rams played in Melbourne, AU):
--   the venue/roof/weather rows read ONLY the event's own venue fields on
--   nfl_partidos (estadio/techado/temperatura/clima_cond). They DO NOT join
--   nfl_estadios/nfl_clima_hora on the home team's espn id, so the LA Rams home
--   stadium (SoFi Stadium / techo_fijo) is NEVER substituted for a neutral-site game.
--   Home/away designation still reads nfl_partidos full team names.
--
-- NO va en supabase/migrations. NO aplicar bajo freeze. Branch-only.
-- ============================================================================

create schema if not exists v2;

-- signature parity with iss030 => drop before recreate.
drop function if exists v2.fn_nfl_dossier_manifest(text, timestamptz);

create or replace function v2.fn_nfl_dossier_manifest(
  p_event_id text, p_decision_time timestamptz default null
) returns table(
  source_name text, provider text, provenance text, available boolean,
  data_asof timestamptz, decision_time timestamptz, freshness_seconds bigint,
  freshness_status text, missing_reason text, role text,
  temporally_safe boolean, used_in_p_reto boolean, post_decision_capture boolean,
  -- same trailing traceability columns as soccer; for NFL they are ALWAYS NULL
  -- because there is no own-model feature snapshot (NO_OWN_MODEL).
  effective_value numeric, feature_snapshot_id uuid, feature_version text,
  max_source_event_time timestamptz
) language plpgsql stable as $$
declare
  v_dec timestamptz;
  np  public.nfl_partidos%rowtype;       -- %rowtype => all fields NULL if no row (fail-closed, no "record not assigned")
  v_matchup text;
  v_np_found boolean := false;
begin
  -- ── 0) canonical event row (full team names live here) ──
  select * into np from public.nfl_partidos p where p.espn_event_id = p_event_id limit 1;
  v_np_found := (np.espn_event_id is not null);
  -- FULL names, away @ home (owner demand: "San Francisco 49ers @ Los Angeles Rams", never "SF @ LAR")
  v_matchup := case when v_np_found then coalesce(np.away_team,'?')||' @ '||coalesce(np.home_team,'?') else null end;

  -- ── 1) decision_time AUTHORITY = latest immutable capture (never kickoff) ──
  v_dec := coalesce(
             p_decision_time,
             (select max(h.capturado_at) from public.nfl_predicciones_historial h
               where h.espn_event_id = p_event_id)
           );
  if v_dec is null then
    return query select 'decision_time'::text,'—'::text,'—'::text,false,
      null::timestamptz,null::timestamptz,null::bigint,'NO_DECISION_TIME'::text,
      'sin decision_time real (nfl_predicciones_historial.capturado_at / argumento): NO se usa kickoff'::text,
      'AVAILABLE_NOT_USED'::text,false,false,false,
      null::numeric,null::uuid,null::text,null::timestamptz;
    return;
  end if;

  return query
  with src as (
    -- ══ MODEL: P_RETO — NFL sin modelo propio => role NO_OWN_MODEL, P_RETO NULL ══
    select 'modelo_p_reto'::text sn,
      'sin modelo propio (NFL)'::text prov,
      -- surfaces the FULL matchup so the shell can render it (never abbreviations)
      ('nfl_predecir es_modelo=false / v_prediccion_reto_nfl P_RETO=NULL — partido: '
        ||coalesce(v_matchup,'(evento no encontrado)'))::text prv,
      false av, null::timestamptz asof, 'MODEL'::text rc,
      ('NFL no tiene modelo independiente de probabilidad: P_RETO=NULL. La cuota no-vig '
       ||'del mercado (nfl_partidos.p_home/p_away) y ESPN-FPI NUNCA son P_RETO.')::text mr,
      false postd

    -- ══ matchup identity row (FULL team names, home/away semantics) ══
    union all select 'matchup','ESPN',
      coalesce(v_matchup,'(sin fila nfl_partidos)')||' (nfl_partidos.away_team @ home_team)',
      v_np_found, np.actualizado, 'CONTEXT',
      case when not v_np_found then 'sin fila nfl_partidos para el evento' end,
      false

    -- ══ MARKET (never P_RETO, used_in_p_reto=false) ══
    -- sportsbook no-vig price carried on nfl_partidos (labelled MARKET, not model)
    union all select 'linea_novig','libro (nfl_partidos.casa)','nfl_partidos.p_home/p_away (no-vig de la casa)',
      (v_np_found and np.p_home is not null and np.actualizado is not null and np.actualizado<=v_dec),
      case when v_np_found and np.actualizado<=v_dec then np.actualizado end,
      'MARKET',
      case when not v_np_found then 'sin fila nfl_partidos'
           when np.p_home is null then 'sin precio no-vig'
           when np.actualizado is null then 'nfl_partidos.actualizado NULL -> as_of no demostrable'
           when np.actualizado>v_dec then 'precio no-vig capturado post-decisión'
           else 'cuota no-vig de la casa — NUNCA es P_RETO' end,
      (v_np_found and np.actualizado is not null and np.actualizado>v_dec)
    -- immutable line snapshots (opening/current) with real snapshot_at
    union all select 'odds_snapshot','libro (nfl_odds_snapshots.casa)','nfl_odds_snapshots',
      exists(select 1 from public.nfl_odds_snapshots o where o.espn_event_id=p_event_id and o.snapshot_at<=v_dec),
      (select max(o.snapshot_at) from public.nfl_odds_snapshots o where o.espn_event_id=p_event_id and o.snapshot_at<=v_dec),
      'MARKET',
      case when not exists(select 1 from public.nfl_odds_snapshots o where o.espn_event_id=p_event_id and o.snapshot_at<=v_dec)
           then 'sin snapshot de línea <= decision' end,
      exists(select 1 from public.nfl_odds_snapshots o where o.espn_event_id=p_event_id and o.snapshot_at>v_dec)
    -- line movement / CLV harness (derived from the immutable historial capture)
    union all select 'movimiento_linea','derivado (CLV)','nfl_predicciones_historial -> v_nfl_movimiento_linea',
      exists(select 1 from public.nfl_predicciones_historial h where h.espn_event_id=p_event_id and h.capturado_at<=v_dec),
      (select max(h.capturado_at) from public.nfl_predicciones_historial h where h.espn_event_id=p_event_id and h.capturado_at<=v_dec),
      'MARKET',
      case when not exists(select 1 from public.nfl_predicciones_historial h where h.espn_event_id=p_event_id and h.capturado_at<=v_dec)
           then 'sin captura de línea <= decision' end,
      exists(select 1 from public.nfl_predicciones_historial h where h.espn_event_id=p_event_id and h.capturado_at>v_dec)

    -- ══ CONTEXT (never MODEL_ACTIVE, never P_RETO) ══
    -- ESPN-FPI opinion — real per-team as_of (nfl_fpi.actualizado); OVERWRITE table
    -- (no history) so a decision in the past can only see a post-decision refresh.
    union all select 'fpi_opinion','ESPN FPI','nfl_fpi (opinión, NO P_RETO)',
      exists(select 1 from public.nfl_fpi f where f.espn_team_id in (np.home_id,np.away_id) and f.actualizado<=v_dec),
      (select max(f.actualizado) from public.nfl_fpi f where f.espn_team_id in (np.home_id,np.away_id) and f.actualizado<=v_dec),
      'CONTEXT',
      case when not v_np_found then 'sin fila nfl_partidos (sin ids de equipo)'
           when not exists(select 1 from public.nfl_fpi f where f.espn_team_id in (np.home_id,np.away_id))
             then 'sin fila FPI para los equipos'
           when not exists(select 1 from public.nfl_fpi f where f.espn_team_id in (np.home_id,np.away_id) and f.actualizado<=v_dec)
             then 'FPI sólo refrescado post-decisión (overwrite, sin historial <= decision) -> no prematch' end,
      exists(select 1 from public.nfl_fpi f where f.espn_team_id in (np.home_id,np.away_id) and f.actualizado>v_dec)
    -- ESPN points model (pred_nfl_espn / mv_fuerza_nfl_espn) — CONTEXT/challenger ONLY,
    -- self-declared Brier 0.246 vs market 0.213 (worse than market); matview stale/no as_of.
    union all select 'puntos_espn','ESPN (challenger)','mv_fuerza_nfl_espn / pred_nfl_espn',
      false, null::timestamptz,'CONTEXT_NOASOF',
      'modelo de puntos challenger (Brier peor que el mercado) y matview sin as_of por fila -> no prematch, nunca P_RETO',
      false
    -- injuries — real cargado_at as_of, keyed by team abbrev + season/week
    union all select 'lesiones','ESPN','nfl_lesiones_semana',
      exists(select 1 from public.nfl_lesiones_semana l where l.temporada=np.temporada and l.semana=np.semana
              and l.equipo in (np.home_abrev,np.away_abrev) and l.cargado_at<=v_dec),
      (select max(l.cargado_at) from public.nfl_lesiones_semana l where l.temporada=np.temporada and l.semana=np.semana
              and l.equipo in (np.home_abrev,np.away_abrev) and l.cargado_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from public.nfl_lesiones_semana l where l.temporada=np.temporada and l.semana=np.semana
              and l.equipo in (np.home_abrev,np.away_abrev) and l.cargado_at<=v_dec) then 'sin lesiones <= decision' end,
      exists(select 1 from public.nfl_lesiones_semana l where l.temporada=np.temporada and l.semana=np.semana
              and l.equipo in (np.home_abrev,np.away_abrev) and l.cargado_at>v_dec)
    -- depth chart — real cargado_at as_of, keyed by team abbrev + season
    union all select 'depth_chart','ESPN','nfl_depth_chart',
      exists(select 1 from public.nfl_depth_chart d where d.temporada=np.temporada
              and d.equipo in (np.home_abrev,np.away_abrev) and d.cargado_at<=v_dec),
      (select max(d.cargado_at) from public.nfl_depth_chart d where d.temporada=np.temporada
              and d.equipo in (np.home_abrev,np.away_abrev) and d.cargado_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from public.nfl_depth_chart d where d.temporada=np.temporada
              and d.equipo in (np.home_abrev,np.away_abrev) and d.cargado_at<=v_dec) then 'sin depth chart <= decision' end,
      exists(select 1 from public.nfl_depth_chart d where d.temporada=np.temporada
              and d.equipo in (np.home_abrev,np.away_abrev) and d.cargado_at>v_dec)
    -- weather — NEUTRAL-SITE SAFE: read ONLY the event's own captured weather on
    -- nfl_partidos; NEVER pull the home team's city weather from nfl_clima_hora.
    union all select 'clima','proveedor','nfl_partidos.clima_cond/temperatura (por-evento)',
      (v_np_found and (np.clima_cond is not null or np.temperatura is not null)),
      null::timestamptz,'CONTEXT_NOASOF',
      'clima por-evento no capturado en nfl_partidos y nfl_clima_hora está keyeada por ciudad del equipo (inválida en sede neutral) -> NO_ASOF, nunca sustituir la sede local',
      false
    -- venue / roof — NEUTRAL-SITE SAFE: read ONLY nfl_partidos.estadio/techado;
    -- NEVER substitute nfl_estadios[home_id] (would falsely assert SoFi/techo_fijo).
    union all select 'venue_roof','ESPN','nfl_partidos.estadio/techado (por-evento)',
      (v_np_found and np.estadio is not null),
      null::timestamptz,'CONTEXT_NOASOF',
      case when v_np_found and np.estadio is null
             then 'sede del evento no capturada (estadio NULL); NO se sustituye el estadio del equipo local (sede neutral-safe); ref estática sin as_of'
           else 'ref estática de sede sin as_of -> no fuente temporal' end,
      false
    -- H2H — keyed by team ids but nfl_h2h.actualizado is a recompute marker, not proof
    -- the aggregate excludes post-decision games => NO_ASOF (fail-closed, como soccer).
    union all select 'h2h','ESPN','nfl_h2h',
      exists(select 1 from public.nfl_h2h x where (x.team_a,x.team_b) in ((np.home_id,np.away_id),(np.away_id,np.home_id))),
      null::timestamptz,'CONTEXT_NOASOF',
      'nfl_h2h.actualizado es marca de recálculo global, no prueba corte temporal por juego -> as_of no demostrable',
      false
    -- rest / bye — no per-row timestamp => NO_ASOF
    union all select 'descanso_bye','ESPN','nfl_bye_weeks',
      exists(select 1 from public.nfl_bye_weeks b where b.temporada=np.temporada and b.equipo_abrev in (np.home_abrev,np.away_abrev)),
      null::timestamptz,'CONTEXT_NOASOF',
      'nfl_bye_weeks sin timestamp por fila -> as_of no demostrable',
      false
    -- standings — nfl_standings has NO updated_at column => NO_ASOF (unlike soccer)
    union all select 'standings','ESPN','nfl_standings',
      exists(select 1 from public.nfl_standings s where s.temporada=np.temporada and s.equipo in (np.home_team,np.away_team)),
      null::timestamptz,'CONTEXT_NOASOF',
      'nfl_standings sin columna de as_of -> no fuente temporal demostrable',
      false
    -- record — denormalized on nfl_partidos, no as_of => NO_ASOF
    union all select 'record','ESPN','nfl_partidos.home_record/away_record',
      (v_np_found and (np.home_record is not null or np.away_record is not null)),
      null::timestamptz,'CONTEXT_NOASOF',
      'record denormalizado sin as_of por fila -> no fuente temporal demostrable',
      false

    -- ══ QUARANTINE: motor_nfl (parallel/legacy uncalibrated) must NOT feed dossier ══
    union all select 'motor_nfl_quarantine','—','public.motor_nfl (motor paralelo sin calibrar)',
      false, null::timestamptz,'QUARANTINE',
      'motor_nfl (soccer-derived, "sin calibrar") en cuarentena: NO alimenta este dossier ni P_RETO',
      false
  )
  select s.sn, s.prov, s.prv, s.av, s.asof, v_dec,
    case when s.asof is null then null else extract(epoch from (v_dec - s.asof))::bigint end,
    -- freshness_status
    case
      when s.rc='MODEL' then 'NO_OWN_MODEL'
      when s.rc='QUARANTINE' then 'QUARANTINE'
      when s.asof is null then 'NO_ASOF'
      when s.asof > v_dec then 'FUTURE_INVALID'
      when v_dec - s.asof <= interval '7 days' then 'FRESH' else 'STALE' end,
    s.mr,
    -- role
    case
      when s.rc='MODEL' then 'NO_OWN_MODEL'
      when s.rc='MARKET' then 'MARKET'
      when s.rc in ('CONTEXT_NOASOF','QUARANTINE') then 'AVAILABLE_NOT_USED'
      else case when s.av and s.asof is not null and s.asof<=v_dec then 'CONTEXT_ONLY' else 'AVAILABLE_NOT_USED' end
    end,
    (s.asof is not null and s.asof<=v_dec),
    -- used_in_p_reto: HARD-WIRED false — NFL has no own model, nothing feeds P_RETO.
    false,
    coalesce(s.postd,false),
    -- trailing traceability: always NULL for NFL (no own-model feature snapshot)
    null::numeric, null::uuid, null::text, null::timestamptz
  from src s;
end $$;

-- Validate on branch (iss049 test): full names for 401872657, neutral-site safety
-- (no SoFi substitution), model row NO_OWN_MODEL, 0 used_in_p_reto, post-decision
-- captures excluded, NO_ASOF sources fail-closed, NO_DECISION_TIME fail-closed.
