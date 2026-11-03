-- ============================================================================
-- iss030 v3 — FULL-DATA PREMATCH DOSSIER MANIFEST (BLOQUE 3, TRAZABILIDAD) · STAGED
-- ============================================================================
-- Reescrito tras AUDIT_NO_PASS (issue #4 comments 5612053961 / 5612773823):
--   FULL_DATA_DOSSIER_TRACEABILITY_GATE=FAIL. Antes (v2) los MODEL_ACTIVE inputs
--   (feat_goal_rate_home/away, feat_sample_counts) tomaban valores y data_asof de
--   v_futpro_v2 (vista de consumo MÓVIL) con provenance genérico
--   v_goles_equipo_futbol.ultimo_partido<=decision. Eso es un timestamp/valor
--   PRESTADO, NO prueba del vector de features EXACTO que alteró P_RETO.
--
-- v3: los MODEL_ACTIVE inputs se resuelven DESDE el snapshot congelado enlazado a la
--   predicción canónica: v2.soccer_prediction_v2_staged.feature_snapshot_id ->
--   v2.feature_snapshot (inmutable, fail-on-drift). El dossier emite los valores
--   FROZEN + feature_data_asof + max_source_event_time + feature_version +
--   feature_snapshot_id + decision_time. Provenance real =
--   v2.feature_snapshot <- historico_partidos_espn (no la vista de consumo).
--
--   used_in_p_reto=true SÓLO si: la predicción canónica es READY con p no nula, tiene
--   feature_snapshot_id enlazado a una fila real de feature_snapshot, feature_data_asof
--   <= decision_time, max_source_event_time <= decision_time, availability_verified
--   (forward) y temporal_safe. Sin feature_snapshot_id / sin fila enlazada =>
--   role=MODEL_ACTIVE_TEMPORAL_UNPROVEN, used_in_p_reto=false (fail-closed, nunca
--   pasa en silencio). El P_RETO mostrado sale de la fila staged congelada, no de
--   v_futpro_v2.
--
--   Fuentes CONTEXT/MARKET siguen leyendo su as_of de ingesta real (tablas fuente),
--   que el audit NO objetó; sólo se corrigió la trazabilidad de las MODEL inputs.
-- Regla dura: valid_prematch_source => data_asof <= decision_time.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- El signature cambió (columnas nuevas) => hay que DROP antes de recrear.
drop function if exists v2.fn_soccer_dossier_manifest(text, timestamptz);

create or replace function v2.fn_soccer_dossier_manifest(
  p_event_id text, p_decision_time timestamptz default null
) returns table(
  source_name text, provider text, provenance text, available boolean,
  data_asof timestamptz, decision_time timestamptz, freshness_seconds bigint,
  freshness_status text, missing_reason text, role text,
  temporally_safe boolean, used_in_p_reto boolean, post_decision_capture boolean,
  -- v3: trazabilidad exacta del vector de features congelado
  effective_value numeric, feature_snapshot_id uuid, feature_version text,
  max_source_event_time timestamptz
) language plpgsql stable as $$
declare
  v_dec timestamptz;
  cfg v2.model_config%rowtype;
  sp  v2.soccer_prediction_v2_staged%rowtype;   -- %rowtype: campos = NULL si no hay fila (fail-closed) sin romper el CTE
  fs  v2.feature_snapshot%rowtype;               -- idem: sin snapshot enlazado, fs.* = NULL, no "record not assigned"
  v_f_dec timestamptz; v_f_home text; v_f_away text;
  v_sp_found boolean := false; v_fs_found boolean := false;
  v_model_ready boolean := false; v_snapshot_linked boolean := false;
  v_temporal_ok boolean := false; v_model_active_ok boolean := false;
  v_home_team text; v_away_team text;
begin
  select * into cfg from v2.model_config where sport='soccer' and model_version='dc-2026.09.1';

  -- ── 1) Predicción CANÓNICA congelada (autoridad = fila staged, no la vista móvil) ──
  if p_decision_time is not null then
    -- iss051: the staged contract is now MULTI-MODEL (domestic dc-2026.09.1 AND
    -- crossleague crossleague_v1 write the SAME table, one row per event). Pinning
    -- model_version to the domestic config here would make the dossier BLIND to every
    -- crossleague P_RETO. The event+decision_time pair already identifies exactly one
    -- row (enforced by v2.v_soccer_staged_identity_violations), so we select by that and
    -- prefer a READY row deterministically instead of filtering by model_version.
    select spp.* into sp from v2.soccer_prediction_v2_staged spp
     where spp.espn_event_id=p_event_id and spp.decision_time=p_decision_time
     order by (spp.model_status like 'READY%') desc, spp.built_at desc
     limit 1;
  else
    select spp.* into sp from v2.soccer_prediction_v2_staged spp
     where spp.espn_event_id=p_event_id
     order by spp.decision_time desc
     limit 1;
  end if;
  v_sp_found := (sp.espn_event_id is not null);

  -- vista de consumo SÓLO como conveniencia de fuentes CONTEXT/MARKET (nunca MODEL).
  -- Opcional: si v_futpro_v2 no existe (p.ej. branch sin data), el dossier NO depende
  -- de ella — la autoridad MODEL es soccer_prediction_v2_staged/feature_snapshot.
  if to_regclass('public.v_futpro_v2') is not null then
    execute 'select coalesce(vf.prediction_time,vf.computed_at), vf.home_team, vf.away_team
               from public.v_futpro_v2 vf where vf.canonical_event_id=$1 limit 1'
      into v_f_dec, v_f_home, v_f_away using p_event_id;
  end if;

  -- decision_time AUTORIDAD: la de la predicción congelada; luego el argumento; luego
  -- (sólo para dossier de un evento sin staged) la de la vista. Sin ninguna -> fail-closed.
  v_dec := coalesce(sp.decision_time, p_decision_time, v_f_dec);
  if v_dec is null then
    return query select 'decision_time'::text,'—','—',false,null::timestamptz,null::timestamptz,
      null::bigint,'NO_DECISION_TIME','sin decision_time real (staged/prediction_time/computed_at): no se usa kickoff',
      'AVAILABLE_NOT_USED',false,false,false,
      null::numeric,null::uuid,null::text,null::timestamptz;
    return;
  end if;

  v_home_team := coalesce(sp.home_team, v_f_home);
  v_away_team := coalesce(sp.away_team, v_f_away);

  -- ── 2) Snapshot de features EXACTO enlazado a esa predicción ──
  if v_sp_found and sp.feature_snapshot_id is not null then
    select fsr.* into fs from v2.feature_snapshot fsr where fsr.feature_snapshot_id=sp.feature_snapshot_id limit 1;
    v_fs_found := (fs.feature_snapshot_id is not null);
  end if;
  v_snapshot_linked := (v_sp_found and sp.feature_snapshot_id is not null and v_fs_found);

  v_model_ready := (v_sp_found and sp.model_status like 'READY%' and sp.p_home is not null);
  -- prueba temporal SOBRE el snapshot congelado (no sobre timestamps prestados)
  v_temporal_ok := (v_snapshot_linked
                    and fs.feature_data_asof is not null and fs.feature_data_asof <= v_dec
                    and (fs.max_source_event_time is null or fs.max_source_event_time <= v_dec)
                    and coalesce(sp.temporal_safe,false)
                    and coalesce(sp.availability_verified,false));  -- forward: disponibilidad exigida
  v_model_active_ok := (v_model_ready and v_temporal_ok);

  return query
  with src as (
    -- ── MODELO: salida P_RETO (de la fila STAGED congelada, no de v_futpro_v2) ──
    select 'modelo_p_reto'::text sn,'motor Dixon-Coles'::text prov,
      'v2.soccer_prediction_v2_staged'::text prv,
      (v_model_ready) av, sp.feature_data_asof asof, 'MODEL'::text rc,
      case when not v_sp_found then 'sin predicción staged para el evento'
           when sp.model_status not like 'READY%' then 'modelo no READY: '||coalesce(sp.model_status,'s/estado')
           else null end mr,
      false postd, sp.p_home eff
    -- ── MODELO: features que ALTERAN P_RETO, resueltas del feature_snapshot EXACTO ──
    union all select 'feat_goal_rate_home','v2.feature_snapshot','v2.feature_snapshot <- historico_partidos_espn',
      (v_snapshot_linked and fs.home_gf is not null), fs.feature_data_asof,'MODEL',
      case when not v_sp_found then 'sin predicción staged'
           when sp.feature_snapshot_id is null then 'predicción sin feature_snapshot_id enlazado'
           when not v_fs_found then 'feature_snapshot_id enlazado no existe'
           when fs.home_gf is null then 'snapshot sin tasa de gol local' end,
      false, fs.home_gf
    union all select 'feat_goal_rate_away','v2.feature_snapshot','v2.feature_snapshot <- historico_partidos_espn',
      (v_snapshot_linked and fs.away_gf is not null), fs.feature_data_asof,'MODEL',
      case when not v_snapshot_linked then 'snapshot de features no enlazado/enlazable'
           when fs.away_gf is null then 'snapshot sin tasa de gol visita' end,
      false, fs.away_gf
    union all select 'feat_sample_counts','v2.feature_snapshot','v2.feature_snapshot (conteo de partidos usados)',
      (v_snapshot_linked and fs.sample_home is not null and fs.sample_away is not null), fs.feature_data_asof,'MODEL',
      case when not v_snapshot_linked then 'snapshot de features no enlazado/enlazable'
           when fs.sample_home is null or fs.sample_away is null then 'snapshot sin muestra' end,
      false, (fs.sample_home + fs.sample_away)::numeric
    -- ── xG (5): usable_pre_kickoff + última captura <= decision ──
    union all select 'xg_forward','proveedor xG','lab_soccer_xg_forward',
      exists(select 1 from lab_soccer_xg_forward x where x.match_id=p_event_id and x.usable_pre_kickoff and x.available_at<=v_dec),
      (select max(available_at) from lab_soccer_xg_forward x where x.match_id=p_event_id and x.usable_pre_kickoff and x.available_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from lab_soccer_xg_forward x where x.match_id=p_event_id and x.usable_pre_kickoff and x.available_at<=v_dec)
           then 'sin xG usable_pre_kickoff <= decision' end,
      exists(select 1 from lab_soccer_xg_forward x where x.match_id=p_event_id and x.available_at>v_dec), null::numeric
    -- ── alineaciones (4): última captura <= decision ──
    union all select 'alineaciones','ESPN','alineaciones_espn',
      exists(select 1 from alineaciones_espn a where a.espn_event_id=p_event_id and a.hay_alineacion and a.capturado_at<=v_dec),
      (select max(capturado_at) from alineaciones_espn a where a.espn_event_id=p_event_id and a.capturado_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from alineaciones_espn a where a.espn_event_id=p_event_id and a.capturado_at<=v_dec) then 'sin alineación <= decision' end,
      exists(select 1 from alineaciones_espn a where a.espn_event_id=p_event_id and a.capturado_at>v_dec), null::numeric
    -- ── arbitro (4) ──
    union all select 'arbitro','ESPN','futbol_arbitro_partido',
      exists(select 1 from futbol_arbitro_partido r where r.espn_event_id=p_event_id and r.cargado_at<=v_dec),
      (select max(cargado_at) from futbol_arbitro_partido r where r.espn_event_id=p_event_id and r.cargado_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from futbol_arbitro_partido r where r.espn_event_id=p_event_id and r.cargado_at<=v_dec) then 'árbitro no cargado <= decision' end,
      exists(select 1 from futbol_arbitro_partido r where r.espn_event_id=p_event_id and r.cargado_at>v_dec), null::numeric
    -- ── standings (4): por liga+equipo, updated_at ──
    union all select 'standings','ESPN','soccer_standings',
      exists(select 1 from soccer_standings s where s.team_nombre=v_home_team and s.updated_at<=v_dec),
      (select max(updated_at) from soccer_standings s where (s.team_nombre=v_home_team or s.team_nombre=v_away_team) and s.updated_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from soccer_standings s where (s.team_nombre=v_home_team or s.team_nombre=v_away_team) and s.updated_at<=v_dec) then 'sin standings <= decision' end,
      false, null::numeric
    -- ── lesiones: sólo LigaMX tiene as_of; resto missing ──
    union all select 'lesiones','ESPN (sólo LigaMX)','ligamx_lesiones',
      false, null::timestamptz,'CONTEXT','cobertura de lesiones con as_of sólo LigaMX; este evento no cubierto', false, null::numeric
    -- ── (6) fuentes SIN as_of de ingesta demostrable ──
    union all select 'h2h','ESPN','bt_h2h', exists(select 1 from bt_h2h h where h.espn_event_id=p_event_id),
      null::timestamptz,'CONTEXT','bt_h2h.fecha es fecha de partido, no as_of de ingesta -> no demostrable', false, null::numeric
    union all select 'descanso','derivado','bt_descanso', exists(select 1 from bt_descanso d where d.espn_event_id=p_event_id),
      null::timestamptz,'CONTEXT','bt_descanso.fecha es fecha de partido, no as_of de ingesta -> no demostrable', false, null::numeric
    union all select 'forma','derivado','bt_forma', exists(select 1 from bt_forma b where b.espn_event_id=p_event_id),
      null::timestamptz,'CONTEXT','bt_forma sin timestamp por fila -> as_of no demostrable', false, null::numeric
    union all select 'clima','proveedor','futbol_clima_hora', false,
      null::timestamptz,'CONTEXT','sin key de evento ni as_of -> no demostrable', false, null::numeric
    union all select 'venue','ref estática','futbol_estadios', true,
      null::timestamptz,'CONTEXT','referencia estática sin versión/as_of -> no se usa como fuente temporal', false, null::numeric
    union all select 'tendencias','externa','tendencias_externas', false,
      null::timestamptz,'CONTEXT','no keyeada por espn_event_id de forma fiable', false, null::numeric
    -- ── MARKET (nunca altera P_RETO) — línea REAL del proveedor (v_momios_confiables) ──
    union all select 'total_line','libro (v_momios_confiables.bookmaker)','v_momios_confiables',
      exists(select 1 from v_momios_confiables mc where mc.espn_event_id=p_event_id and mc.confiable and mc.over_line is not null and mc.snapshot_at<=v_dec),
      (select max(snapshot_at) from v_momios_confiables mc where mc.espn_event_id=p_event_id and mc.confiable and mc.over_line is not null and mc.snapshot_at<=v_dec),
      'MARKET',
      case when not exists(select 1 from v_momios_confiables mc where mc.espn_event_id=p_event_id and mc.confiable and mc.over_line is not null and mc.snapshot_at<=v_dec) then 'sin línea real confiable <= decision -> O/U fail-closed' end,
      exists(select 1 from v_momios_confiables mc where mc.espn_event_id=p_event_id and mc.snapshot_at>v_dec), null::numeric
    union all select 'odds_mercado','libro','v_momios_confiables',
      exists(select 1 from v_momios_confiables mc where mc.espn_event_id=p_event_id and mc.snapshot_at<=v_dec),
      (select max(snapshot_at) from v_momios_confiables mc where mc.espn_event_id=p_event_id and mc.snapshot_at<=v_dec),
      'MARKET', null, exists(select 1 from v_momios_confiables mc where mc.espn_event_id=p_event_id and mc.snapshot_at>v_dec), null::numeric
    union all select 'odds_pro','Pinnacle+','odds_pro_snapshots',
      exists(select 1 from odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at<=v_dec),
      (select max(created_at) from odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at<=v_dec),
      'MARKET', null, exists(select 1 from odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at>v_dec), null::numeric
  )
  select s.sn, s.prov, s.prv, s.av, s.asof, v_dec,
    case when s.asof is null then null else extract(epoch from (v_dec - s.asof))::bigint end,
    -- freshness_status: para MODEL sin snapshot enlazado, señal explícita UNPROVEN
    case
      when s.rc='MODEL' and not v_snapshot_linked then 'MODEL_ACTIVE_TEMPORAL_UNPROVEN'
      when s.asof is null then 'NO_ASOF'
      when s.asof > v_dec then 'FUTURE_INVALID'
      when v_dec - s.asof <= interval '48 hours' then 'FRESH' else 'STALE' end,
    s.mr,
    -- role
    case
      when s.rc='MODEL' then
        case when v_model_active_ok and s.av and s.asof is not null and s.asof<=v_dec then 'MODEL_ACTIVE'
             when v_model_ready and not v_snapshot_linked then 'MODEL_ACTIVE_TEMPORAL_UNPROVEN'
             else 'AVAILABLE_NOT_USED' end
      when s.rc='MARKET' then 'AVAILABLE_NOT_USED'
      else case when s.av and s.asof is not null and s.asof<=v_dec then 'CONTEXT_ONLY' else 'AVAILABLE_NOT_USED' end
    end,
    (s.asof is not null and s.asof<=v_dec),
    -- used_in_p_reto: sólo MODEL con snapshot exacto enlazado + prueba temporal
    (s.rc='MODEL' and v_model_active_ok and s.av and s.asof is not null and s.asof<=v_dec),
    coalesce(s.postd,false),
    -- v3 trazabilidad
    s.eff,
    case when s.rc='MODEL' and v_snapshot_linked then fs.feature_snapshot_id else null end,
    case when s.rc='MODEL' and v_snapshot_linked then fs.feature_version else null end,
    case when s.rc='MODEL' and v_snapshot_linked then fs.max_source_event_time else null end
  from src s;
end $$;

-- Validar en 2 eventos: READY (con feature_snapshot enlazado) y fail-closed (401915446).
-- Regresión clave: mutar los agregados móviles (historico/v_goles_equipo_futbol) DESPUÉS
-- de sellar la predicción NO cambia los valores/as_of/snapshot_id MODEL del dossier.
