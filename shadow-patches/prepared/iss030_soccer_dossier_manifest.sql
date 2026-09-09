-- ============================================================================
-- iss030 v2 — FULL-DATA PREMATCH DOSSIER MANIFEST (BLOQUE 3, ENDURECIDO) · STAGED
-- ============================================================================
-- Reescrito tras AUDIT_NO_PASS (issue #4 comment 5606659045), findings 2-9:
--  (2) el manifiesto EMITE todas las fuentes inventariadas (no sólo catálogo).
--  (3) decision_time NO cae a kickoff: si no hay prediction_time/computed_at real
--      -> fila única NO_DECISION_TIME (fail-closed).
--  (4) por fuente multi-captura se usa la ÚLTIMA captura <= decision_time
--      (max(ts) FILTER (ts<=dec)), y se marca si existen capturas post-decisión.
--  (5) xg exige usable_pre_kickoff=true además de available_at<=decision.
--  (6) h2h.fecha / descanso.fecha / forma / clima NO son as_of de ingesta ->
--      NO_ASOF / AVAILABLE_NOT_USED con razón; venue = referencia estática sin
--      versión -> AVAILABLE_NOT_USED (no se inventa as_of).
--  (7) se EMITEN los inputs MODEL_ACTIVE del modelo (tasas de gol home/away,
--      muestra) con su propio as_of (v_futpro_v2.data_asof = corte de datos del
--      modelo; provenance v_goles_equipo_futbol.ultimo_partido). Sin as_of -> no MODEL_ACTIVE.
--  (9) capturas posteriores a decision_time nunca cuentan como cobertura prematch.
-- Regla dura: valid_prematch_source => data_asof <= decision_time.
-- NO va en supabase/migrations. NO aplicar bajo freeze.
-- ============================================================================

-- (catálogo v2.dossier_source_catalog se mantiene de la versión previa; ver iss030 base)

create or replace function v2.fn_soccer_dossier_manifest(
  p_event_id text, p_decision_time timestamptz default null
) returns table(
  source_name text, provider text, provenance text, available boolean,
  data_asof timestamptz, decision_time timestamptz, freshness_seconds bigint,
  freshness_status text, missing_reason text, role text,
  temporally_safe boolean, used_in_p_reto boolean, post_decision_capture boolean
) language plpgsql stable as $$
declare v_dec timestamptz; f record; v_model_ok boolean;
begin
  select coalesce(prediction_time,computed_at) dec, data_asof, kickoff, model_status,
         p_reto_home, p_reto_draw, p_reto_away, temporal_safe,
         home_gf_pg, home_gc_pg, away_gf_pg, away_gc_pg, sample_home, sample_away,
         over_line, line_source, btts_yes, home_team, away_team, competition_name
    into f
  from v_futpro_v2 where canonical_event_id=p_event_id limit 1;

  -- (3) NO fallback a kickoff. Sin decision snapshot real -> fail-closed.
  v_dec := coalesce(p_decision_time, f.dec);
  if v_dec is null then
    return query select 'decision_time'::text,'—','—',false,null::timestamptz,null::timestamptz,
      null::bigint,'NO_DECISION_TIME','sin prediction_time/computed_at real: no se usa kickoff como sustituto',
      'AVAILABLE_NOT_USED',false,false,false;
    return;
  end if;

  v_model_ok := (f.model_status like 'READY%' and f.p_reto_home is not null
                 and f.data_asof is not null and f.data_asof<=v_dec and coalesce(f.temporal_safe,false));

  return query
  with src as (
    -- ── MODELO: salida P_RETO ──
    select 'modelo_p_reto'::text sn,'motor Dixon-Coles'::text prov,'v_futpro_v2'::text prv,
      (f.model_status like 'READY%' and f.p_reto_home is not null) av, f.data_asof asof,'MODEL'::text rc,
      case when f.model_status like 'READY%' then null else 'modelo no READY: '||coalesce(f.model_status,'s/estado') end mr, false postd
    -- ── MODELO: inputs (features) que ALTERAN P_RETO, con su propio as_of ──
    union all select 'feat_goal_rate_home','v_goles_equipo_futbol','ultimo_partido<=decision',
      (f.home_gf_pg is not null), f.data_asof,'MODEL',
      case when f.home_gf_pg is null then 'sin tasa de gol local' end, false
    union all select 'feat_goal_rate_away','v_goles_equipo_futbol','ultimo_partido<=decision',
      (f.away_gf_pg is not null), f.data_asof,'MODEL',
      case when f.away_gf_pg is null then 'sin tasa de gol visita' end, false
    union all select 'feat_sample_counts','v_goles_equipo_futbol','conteo de partidos usados',
      (f.sample_home is not null and f.sample_away is not null), f.data_asof,'MODEL',
      case when f.sample_home is null then 'sin muestra' end, false
    -- ── xG (5): usable_pre_kickoff + última captura <= decision ──
    union all select 'xg_forward','proveedor xG','lab_soccer_xg_forward',
      exists(select 1 from lab_soccer_xg_forward x where x.match_id=p_event_id and x.usable_pre_kickoff and x.available_at<=v_dec),
      (select max(available_at) from lab_soccer_xg_forward x where x.match_id=p_event_id and x.usable_pre_kickoff and x.available_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from lab_soccer_xg_forward x where x.match_id=p_event_id and x.usable_pre_kickoff and x.available_at<=v_dec)
           then 'sin xG usable_pre_kickoff <= decision' end,
      exists(select 1 from lab_soccer_xg_forward x where x.match_id=p_event_id and x.available_at>v_dec)
    -- ── alineaciones (4): última captura <= decision ──
    union all select 'alineaciones','ESPN','alineaciones_espn',
      exists(select 1 from alineaciones_espn a where a.espn_event_id=p_event_id and a.hay_alineacion and a.capturado_at<=v_dec),
      (select max(capturado_at) from alineaciones_espn a where a.espn_event_id=p_event_id and a.capturado_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from alineaciones_espn a where a.espn_event_id=p_event_id and a.capturado_at<=v_dec) then 'sin alineación <= decision' end,
      exists(select 1 from alineaciones_espn a where a.espn_event_id=p_event_id and a.capturado_at>v_dec)
    -- ── arbitro (4) ──
    union all select 'arbitro','ESPN','futbol_arbitro_partido',
      exists(select 1 from futbol_arbitro_partido r where r.espn_event_id=p_event_id and r.cargado_at<=v_dec),
      (select max(cargado_at) from futbol_arbitro_partido r where r.espn_event_id=p_event_id and r.cargado_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from futbol_arbitro_partido r where r.espn_event_id=p_event_id and r.cargado_at<=v_dec) then 'árbitro no cargado <= decision' end,
      exists(select 1 from futbol_arbitro_partido r where r.espn_event_id=p_event_id and r.cargado_at>v_dec)
    -- ── standings (4): por liga+equipo, updated_at ──
    union all select 'standings','ESPN','soccer_standings',
      exists(select 1 from soccer_standings s where s.team_nombre=f.home_team and s.updated_at<=v_dec),
      (select max(updated_at) from soccer_standings s where (s.team_nombre=f.home_team or s.team_nombre=f.away_team) and s.updated_at<=v_dec),
      'CONTEXT',
      case when not exists(select 1 from soccer_standings s where (s.team_nombre=f.home_team or s.team_nombre=f.away_team) and s.updated_at<=v_dec) then 'sin standings <= decision' end,
      false
    -- ── lesiones: sólo LigaMX tiene as_of; resto missing ──
    union all select 'lesiones','ESPN (sólo LigaMX)','ligamx_lesiones',
      false, null::timestamptz,'CONTEXT','cobertura de lesiones con as_of sólo LigaMX; este evento no cubierto', false
    -- ── (6) fuentes SIN as_of de ingesta demostrable ──
    union all select 'h2h','ESPN','bt_h2h', exists(select 1 from bt_h2h h where h.espn_event_id=p_event_id),
      null::timestamptz,'CONTEXT','bt_h2h.fecha es fecha de partido, no as_of de ingesta -> no demostrable', false
    union all select 'descanso','derivado','bt_descanso', exists(select 1 from bt_descanso d where d.espn_event_id=p_event_id),
      null::timestamptz,'CONTEXT','bt_descanso.fecha es fecha de partido, no as_of de ingesta -> no demostrable', false
    union all select 'forma','derivado','bt_forma', exists(select 1 from bt_forma b where b.espn_event_id=p_event_id),
      null::timestamptz,'CONTEXT','bt_forma sin timestamp por fila -> as_of no demostrable', false
    union all select 'clima','proveedor','futbol_clima_hora', false,
      null::timestamptz,'CONTEXT','sin key de evento ni as_of -> no demostrable', false
    union all select 'venue','ref estática','futbol_estadios', true,
      null::timestamptz,'CONTEXT','referencia estática sin versión/as_of -> no se usa como fuente temporal', false
    union all select 'tendencias','externa','tendencias_externas', false,
      null::timestamptz,'CONTEXT','no keyeada por espn_event_id de forma fiable', false
    -- ── MARKET (nunca altera P_RETO) — última captura <= decision ──
    union all select 'total_line','libro','momios_mercado.total_linea',
      exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id and m.total_linea is not null and m.actualizado<=v_dec),
      (select max(actualizado) from momios_mercado m where m.espn_event_id=p_event_id and m.total_linea is not null and m.actualizado<=v_dec),
      'MARKET',
      case when not exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id and m.total_linea is not null and m.actualizado<=v_dec) then 'sin línea real <= decision' end,
      exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id and m.actualizado>v_dec)
    union all select 'odds_mercado','libro','momios_mercado',
      exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id and m.actualizado<=v_dec),
      (select max(actualizado) from momios_mercado m where m.espn_event_id=p_event_id and m.actualizado<=v_dec),
      'MARKET', null, exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id and m.actualizado>v_dec)
    union all select 'odds_pro','Pinnacle+','odds_pro_snapshots',
      exists(select 1 from odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at<=v_dec),
      (select max(created_at) from odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at<=v_dec),
      'MARKET', null, exists(select 1 from odds_pro_snapshots o where o.espn_event_id=p_event_id and o.created_at>v_dec)
  )
  select s.sn, s.prov, s.prv, s.av, s.asof, v_dec,
    case when s.asof is null then null else extract(epoch from (v_dec - s.asof))::bigint end,
    case when s.asof is null then 'NO_ASOF'
         when s.asof > v_dec then 'FUTURE_INVALID'   -- no debería ocurrir (ya filtramos <=dec), defensa
         when v_dec - s.asof <= interval '48 hours' then 'FRESH' else 'STALE' end,
    s.mr,
    case
      when s.rc='MODEL' then case when v_model_ok and s.av and s.asof is not null and s.asof<=v_dec then 'MODEL_ACTIVE' else 'AVAILABLE_NOT_USED' end
      when s.rc='MARKET' then 'AVAILABLE_NOT_USED'
      else case when s.av and s.asof is not null and s.asof<=v_dec then 'CONTEXT_ONLY' else 'AVAILABLE_NOT_USED' end
    end,
    (s.asof is not null and s.asof<=v_dec),
    (s.rc='MODEL' and v_model_ok and s.av and s.asof is not null and s.asof<=v_dec),
    coalesce(s.postd,false)
  from src s;
end $$;

-- Validar en 2 eventos reales: READY dom (401885470 Moreirense-Benfica) y fail-closed (401915446).
