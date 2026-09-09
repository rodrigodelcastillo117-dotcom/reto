-- ============================================================================
-- iss030 — FULL-DATA PREMATCH DOSSIER MANIFEST (BLOQUE 3) · STAGED, NO APLICAR
-- ============================================================================
-- Manifiesto por evento y POR FUENTE INDIVIDUAL. Regla dura: data_asof <= decision_time.
-- Si una fuente no tiene data_asof demostrable POR FILA: NO se inventa, NO se reusa el
-- timestamp del modelo, NO puede ser MODEL_ACTIVE -> AVAILABLE_NOT_USED / missing con razón.
-- role ∈ {MODEL_ACTIVE, CONTEXT_ONLY, AVAILABLE_NOT_USED}. Sólo el modelo altera P_RETO.
-- NO va en supabase/migrations. Read-only sobre fuentes reales (inventariadas 2026-09-09).
-- ============================================================================

-- ── Catálogo REAL de fuentes de dossier de fútbol (inventario verificado) ─────
create table if not exists v2.dossier_source_catalog (
  source_name text primary key, provider text, provenance text,
  tabla text, key_type text, timestamp_col text, role_class text, nota text
);
truncate v2.dossier_source_catalog;
insert into v2.dossier_source_catalog values
 ('modelo_p_reto','motor Dixon-Coles','v2.build_soccer_prediction_v2','v_futpro_v2','espn_event_id','data_asof','MODEL','única fuente que altera P_RETO'),
 ('xg_forward','proveedor xG','lab_soccer_xg_forward','historico/modelo','match_id','available_at','CONTEXT','tiene usable_pre_kickoff + available_at (estándar de oro temporal)'),
 ('alineaciones','ESPN','alineaciones_espn','ESPN','espn_event_id','capturado_at','CONTEXT','capturado_at + minutos_antes; hay_alineacion'),
 ('arbitro','ESPN','futbol_arbitro_partido','ESPN','espn_event_id','cargado_at','CONTEXT','árbitro suele conocerse ~1h antes'),
 ('h2h','ESPN','bt_h2h','ESPN','espn_event_id','fecha','CONTEXT','h2h_* precomputado de partidos previos'),
 ('descanso','derivado','bt_descanso','ESPN','espn_event_id','fecha','CONTEXT','dias_descanso, conocido al kickoff'),
 ('standings','ESPN','soccer_standings','ESPN','liga_id+team_id','updated_at','CONTEXT','posición/puntos/forma de tabla'),
 ('tendencias','365Scores/externa','tendencias_externas','externa','espn_event_id?','capturado_at','CONTEXT','factual, verificado_vs_espn'),
 ('forma','derivado','bt_forma','ESPN','espn_event_id',NULL,'CONTEXT','SIN timestamp por fila -> data_asof NO demostrable'),
 ('clima','proveedor clima','futbol_clima_hora','externa','estadio+hora_utc',NULL,'CONTEXT','sin key de evento ni as_of -> no demostrable'),
 ('lesiones','—','(sólo ligamx_lesiones)','ESPN','equipo','updated_at','CONTEXT','cobertura SÓLO LigaMX; resto missing'),
 ('venue','ref estática','futbol_estadios/estadios_altitud','ESPN','estadio',NULL,'CONTEXT','referencia estática (sin riesgo temporal)'),
 ('odds_mercado','libro','momios_mercado','the_odds_api/ESPN','espn_event_id','actualizado','MARKET','probability-first: NUNCA altera P_RETO'),
 ('total_line','libro','momios_mercado.total_linea','the_odds_api','espn_event_id','actualizado','MARKET','ancla mercado O/U; no recalcula P'),
 ('odds_pro','Pinnacle+','odds_pro_snapshots','pinnacle','espn_event_id','created_at','MARKET','open/close; EV/CLV NO entran a P_RETO');

-- ── Función de manifiesto por evento ─────────────────────────────────────────
-- decision_time por defecto = prediction_time ?? computed_at ?? kickoff de v_futpro_v2.
create or replace function v2.fn_soccer_dossier_manifest(
  p_event_id text, p_decision_time timestamptz default null
) returns table(
  source_name text, provider text, provenance text, available boolean,
  data_asof timestamptz, decision_time timestamptz, freshness_seconds bigint,
  freshness_status text, missing_reason text, role text,
  temporally_safe boolean, used_in_p_reto boolean
) language plpgsql stable as $$
declare v_dec timestamptz; v_model record;
begin
  select f.data_asof, coalesce(f.prediction_time,f.computed_at) dec, f.kickoff, f.model_status,
         f.p_reto_home, f.p_reto_draw, f.p_reto_away, f.temporal_safe
    into v_model
  from v_futpro_v2 f where f.canonical_event_id = p_event_id limit 1;
  v_dec := coalesce(p_decision_time, v_model.dec, v_model.kickoff);

  -- helper inline via VALUES: (source, available, data_asof, role_class, missing_reason)
  return query
  with probes as (
    -- MODEL
    select 'modelo_p_reto'::text sn,
      (v_model.model_status like 'READY%' and v_model.p_reto_home is not null) as av,
      v_model.data_asof as asof, 'MODEL'::text rc,
      case when v_model.model_status like 'READY%' then null else 'modelo no READY: '||coalesce(v_model.model_status,'s/estado') end mr
    union all
    select 'xg_forward', exists(select 1 from lab_soccer_xg_forward x where x.match_id=p_event_id),
      (select max(available_at) from lab_soccer_xg_forward x where x.match_id=p_event_id), 'CONTEXT',
      case when exists(select 1 from lab_soccer_xg_forward x where x.match_id=p_event_id) then null else 'sin fila xG para el evento' end
    union all
    select 'alineaciones', exists(select 1 from alineaciones_espn a where a.espn_event_id=p_event_id and a.hay_alineacion),
      (select max(capturado_at) from alineaciones_espn a where a.espn_event_id=p_event_id), 'CONTEXT',
      case when exists(select 1 from alineaciones_espn a where a.espn_event_id=p_event_id) then null else 'sin alineación capturada' end
    union all
    select 'arbitro', exists(select 1 from futbol_arbitro_partido r where r.espn_event_id=p_event_id),
      (select max(cargado_at) from futbol_arbitro_partido r where r.espn_event_id=p_event_id), 'CONTEXT',
      case when exists(select 1 from futbol_arbitro_partido r where r.espn_event_id=p_event_id) then null else 'árbitro no asignado aún' end
    union all
    select 'h2h', exists(select 1 from bt_h2h h where h.espn_event_id=p_event_id),
      (select max(fecha) from bt_h2h h where h.espn_event_id=p_event_id), 'CONTEXT',
      case when exists(select 1 from bt_h2h h where h.espn_event_id=p_event_id) then null else 'sin H2H precomputado' end
    union all
    select 'descanso', exists(select 1 from bt_descanso d where d.espn_event_id=p_event_id),
      (select max(fecha) from bt_descanso d where d.espn_event_id=p_event_id), 'CONTEXT',
      case when exists(select 1 from bt_descanso d where d.espn_event_id=p_event_id) then null else 'sin dato de descanso' end
    union all
    select 'tendencias', exists(select 1 from tendencias_externas t where t.partido is not null and false),
      null::timestamptz, 'CONTEXT', 'no keyeada por espn_event_id de forma fiable -> missing'
    union all
    -- fuentes SIN data_asof por fila demostrable: available pero as_of NO demostrable
    select 'forma', exists(select 1 from bt_forma bf where bf.espn_event_id=p_event_id),
      null::timestamptz, 'CONTEXT',
      case when exists(select 1 from bt_forma bf where bf.espn_event_id=p_event_id)
           then 'fuente sin timestamp por fila: data_asof NO demostrable' else 'sin forma' end
    union all
    select 'clima', false, null::timestamptz, 'CONTEXT', 'sin key de evento ni as_of: no demostrable'
    union all
    -- MARKET (nunca altera P_RETO)
    select 'total_line', exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id and m.total_linea is not null),
      (select max(actualizado) from momios_mercado m where m.espn_event_id=p_event_id), 'MARKET',
      case when exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id and m.total_linea is not null) then null else 'sin línea de totales real' end
    union all
    select 'odds_mercado', exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id),
      (select max(actualizado) from momios_mercado m where m.espn_event_id=p_event_id), 'MARKET',
      case when exists(select 1 from momios_mercado m where m.espn_event_id=p_event_id) then null else 'sin momios' end
  )
  select
    pr.sn,
    cat.provider, cat.provenance,
    pr.av,
    pr.asof,
    v_dec,
    case when pr.asof is null then null else extract(epoch from (v_dec - pr.asof))::bigint end,
    case
      when pr.asof is null then 'NO_ASOF'
      when pr.asof > v_dec then 'FUTURE_INVALID'         -- fuga temporal
      when v_dec - pr.asof <= interval '48 hours' then 'FRESH'
      else 'STALE' end,
    pr.mr,
    -- role: MODEL_ACTIVE sólo si modelo disponible + as_of<=decision; MARKET siempre AVAILABLE_NOT_USED;
    -- CONTEXT_ONLY sólo si available + as_of demostrable + as_of<=decision; si no -> AVAILABLE_NOT_USED
    case
      when pr.rc='MODEL' then case when pr.av and pr.asof is not null and pr.asof<=v_dec and v_model.temporal_safe then 'MODEL_ACTIVE' else 'AVAILABLE_NOT_USED' end
      when pr.rc='MARKET' then 'AVAILABLE_NOT_USED'
      else case when pr.av and pr.asof is not null and pr.asof<=v_dec then 'CONTEXT_ONLY' else 'AVAILABLE_NOT_USED' end
    end,
    (pr.asof is not null and pr.asof<=v_dec),
    (pr.rc='MODEL' and pr.av and pr.asof is not null and pr.asof<=v_dec and v_model.temporal_safe)
  from probes pr
  left join v2.dossier_source_catalog cat on cat.source_name=pr.sn;
end $$;

-- Uso: select * from v2.fn_soccer_dossier_manifest('401915446');  -- Liverpool-Atlético
