-- ISS136 — Soccer canonical selector + Reto13M release path
-- 2026-09-13
-- Purpose:
-- 1) enforce exact crossleague model identity at persistence boundary,
-- 2) certify a single deterministic soccer selector: argmax of canonical 1X2 P_RETO only,
-- 3) route Reto13M Lo Mejor to the same FutPro V3 canonical brain,
-- 4) keep odds/EV/Kelly diagnostic-only and legacy money publication closed.

create or replace function v2.enforce_soccer_prediction_model_identity()
returns trigger
language plpgsql
set search_path='v2','public'
as $$
declare v_engine text;
begin
  if new.model_name='reto_crossleague' then
    v_engine := nullif(new.provenance->>'engine','');
    if v_engine ~ '^crossleague_v[0-9]+(_[0-9]+)?$' then
      if exists (
        select 1 from v2.crossleague_competition_policy p
        where p.competition_id=new.competition_id
          and p.model_version=v_engine
          and p.status='PROD_APPROVED'
      ) then
        new.model_version := v_engine;
      end if;
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_soccer_prediction_model_identity on v2.soccer_prediction_v2;
create trigger trg_soccer_prediction_model_identity
before insert or update on v2.soccer_prediction_v2
for each row execute function v2.enforce_soccer_prediction_model_identity();

-- Repair already-persisted rows only when the provenance engine is itself approved
-- for the exact canonical competition.
update v2.soccer_prediction_v2 s
set model_version=s.provenance->>'engine'
where s.model_name='reto_crossleague'
  and nullif(s.provenance->>'engine','') ~ '^crossleague_v[0-9]+(_[0-9]+)?$'
  and s.model_version is distinct from s.provenance->>'engine'
  and exists (
    select 1 from v2.crossleague_competition_policy p
    where p.competition_id=s.competition_id
      and p.model_version=s.provenance->>'engine'
      and p.status='PROD_APPROVED'
  );

create or replace view public.v_futpro_publication_v3 as
with q as (
  select v.*,
    exists (
      select 1 from v2.crossleague_competition_policy p
      where p.competition_id=v.competition_id
        and p.model_version=v.model_version
        and p.status='PROD_APPROVED'
    ) as policy_ok,
    (v.p_reto_home is not null and v.p_reto_draw is not null and v.p_reto_away is not null
      and abs((v.p_reto_home+v.p_reto_draw+v.p_reto_away)-100.0)<=0.2) as dist_ok,
    (v.p_reto_home>v.p_reto_draw and v.p_reto_home>v.p_reto_away) as home_unique,
    (v.p_reto_draw>v.p_reto_home and v.p_reto_draw>v.p_reto_away) as draw_unique,
    (v.p_reto_away>v.p_reto_home and v.p_reto_away>v.p_reto_draw) as away_unique
  from public.v_futpro_v2 v
), g as (
  select q.*,
    (model_status in ('READY','READY_UNVALIDATED')
      and temporal_safe is true
      and data_asof is not null and prediction_time is not null
      and data_asof<=prediction_time
      and (computed_at is null or prediction_time<=computed_at)
      and calibration_status='OOS_VALIDATED'
      and policy_ok and dist_ok
      and model_version is not null
      and engine=model_version) as base_ready,
    (home_unique or draw_unique or away_unique) as unique_winner
  from q
)
select
  g.snapshot_id,g.canonical_event_id,g.competition_id,g.competition_name,g.group_name,g.display_order,g.show_in_futpro,g.show_in_favorites,
  g.home_team,g.away_team,g.kickoff,g.event_status,g.escudo_home,g.escudo_away,g.p_reto_home,g.p_reto_draw,g.p_reto_away,
  g.predicted_score,g.predicted_score_prob,g.score_dist,g.score_available,g.btts_yes,g.over_line,g.p_over,g.p_under,g.line_source,
  g.mejor_pick,g.mejor_pick_prob,g.markets,g.exp_goals_total,g.lambda_home,g.lambda_away,g.home_gf_pg,g.home_gc_pg,g.away_gf_pg,g.away_gc_pg,
  g.home_btts_pct,g.away_btts_pct,g.sample_home,g.sample_away,g.odds_home,g.odds_draw,g.odds_away,g.odds_over,g.odds_under,g.odds_bookmaker,g.odds_captured_at,
  g.model_status,g.model_status_reason,g.model_name,g.model_version,g.feature_version,g.calibration_status,g.temporal_safe,g.data_asof,g.prediction_time,g.computed_at,g.source_created_at,g.engine,g.narrative,
  case
    when g.model_status is null or g.model_status not in ('READY','READY_UNVALIDATED') then 'MODEL_UNAVAILABLE'
    when g.temporal_safe is distinct from true then 'TEMPORAL_UNSAFE'
    when g.data_asof is null or g.prediction_time is null then 'LINEAGE_INCOMPLETE'
    when g.data_asof>g.prediction_time then 'TEMPORAL_UNSAFE'
    when g.computed_at is not null and g.prediction_time>g.computed_at then 'LINEAGE_INCONSISTENT'
    when g.calibration_status is distinct from 'OOS_VALIDATED' then 'CALIBRATION_UNVALIDATED'
    when not g.policy_ok then 'MODEL_POLICY_NOT_APPROVED'
    when not g.dist_ok then 'DISTRIBUTION_INVALID'
    when g.engine is distinct from g.model_version then 'MODEL_IDENTITY_MISMATCH'
    when not g.unique_winner then 'TIE_UNRESOLVED'
    else 'READY'
  end as canonical_pick_status,
  case when g.base_ready and g.unique_winner then 'Moneyline' end as canonical_market,
  case when g.base_ready and g.unique_winner then
    case when g.home_unique then 'Gana '||g.home_team when g.draw_unique then 'Empate' else 'Gana '||g.away_team end
  end as canonical_pick,
  case when g.base_ready and g.unique_winner then greatest(g.p_reto_home,g.p_reto_draw,g.p_reto_away) end as canonical_pick_prob,
  null::numeric as canonical_line,
  'soccer_1x2_argmax_v1'::text as selector_version,
  (g.base_ready and g.unique_winner) as selector_authoritative,
  false as top_only_authoritative,
  case
    when g.base_ready and g.unique_winner then 'Selector 1X2 congelado: argmax unico de P_RETO; momios/EV/Kelly no participan.'
    when g.engine is distinct from g.model_version then 'Linaje inconsistente: engine y model_version no coinciden.'
    when g.base_ready and not g.unique_winner then 'Empate exacto entre dos salidas 1X2; no se fuerza un lado.'
    else 'Prediccion no supera todas las guardas de publicacion.'
  end as canonical_pick_reason,
  jsonb_build_object(
    'model_name',g.model_name,'model_version',g.model_version,'feature_version',g.feature_version,'calibration_status',g.calibration_status,
    'model_status',g.model_status,'temporal_safe',g.temporal_safe,'data_asof',g.data_asof,'prediction_time',g.prediction_time,'computed_at',g.computed_at,
    'line_source',g.line_source,'selector_version','soccer_1x2_argmax_v1','legacy_mejor_pick_is_authoritative',false,'odds_ev_kelly_allowed_to_select',false,
    'competition_policy_approved',g.policy_ok,'distribution_valid',g.dist_ok,'engine_matches_model_version',(g.engine=g.model_version)
  ) as publication_lineage,
  'soccer_1x2_argmax_v1'::text as canonical_pick_version,
  'EVENT_SELECTOR_FROZEN'::text as rank_policy_status
from g;

-- RETO13M now consumes the same soccer publication contract as FutPro.
-- Existing columns are preserved in place; frontend release-contract fields are appended.
create or replace view public.v_reto13m_lo_mejor as
with c as (
  select
    v.canonical_event_id as espn_event_id,
    'soccer'::text as deporte,
    v.competition_name as liga,
    v.home_team as home,
    v.away_team as away,
    v.kickoff as arranca_en,
    case
      when (v.kickoff at time zone 'America/Mexico_City')::date=(now() at time zone 'America/Mexico_City')::date
        then 'HOY '||to_char(v.kickoff at time zone 'America/Mexico_City','HH12:MI am')
      when (v.kickoff at time zone 'America/Mexico_City')::date=((now() at time zone 'America/Mexico_City')::date+1)
        then 'MANANA '||to_char(v.kickoff at time zone 'America/Mexico_City','HH12:MI am')
      else to_char(v.kickoff at time zone 'America/Mexico_City','DD/MM - HH12:MI am')
    end as etiqueta_cuando,
    v.canonical_market as mercado,
    v.canonical_pick as pick_nombre,
    v.canonical_pick as pick_desc,
    v.canonical_pick_prob as probabilidad_pct,
    v.model_version,
    v.calibration_status as calibration_version,
    'VALIDADO'::text as respaldo,
    case
      when v.canonical_pick='Gana '||v.home_team then v.odds_home
      when v.canonical_pick='Empate' then v.odds_draw
      when v.canonical_pick='Gana '||v.away_team then v.odds_away
    end as momio_mercado,
    v.odds_bookmaker as casa,
    true as es_lock,
    true as validado_fuera_de_muestra,
    v.p_reto_home,v.p_reto_draw,v.p_reto_away,
    v.sample_home,v.sample_away,
    v.canonical_pick_status,v.selector_authoritative,v.canonical_pick_version
  from public.v_futpro_publication_v3 v
  where v.kickoff>now()
    and v.canonical_pick_status='READY'
    and v.selector_authoritative=true
), scored as (
  select c.*,
    (c.probabilidad_pct-(c.p_reto_home+c.p_reto_draw+c.p_reto_away
      -greatest(c.p_reto_home,c.p_reto_draw,c.p_reto_away)
      -least(c.p_reto_home,c.p_reto_draw,c.p_reto_away))) as discriminacion_pp,
    row_number() over(order by c.probabilidad_pct desc,
      (c.probabilidad_pct-(c.p_reto_home+c.p_reto_draw+c.p_reto_away
      -greatest(c.p_reto_home,c.p_reto_draw,c.p_reto_away)
      -least(c.p_reto_home,c.p_reto_draw,c.p_reto_away))) desc,
      c.arranca_en,c.espn_event_id) as rank_global,
    row_number() over(partition by c.deporte order by c.probabilidad_pct desc,
      (c.probabilidad_pct-(c.p_reto_home+c.p_reto_draw+c.p_reto_away
      -greatest(c.p_reto_home,c.p_reto_draw,c.p_reto_away)
      -least(c.p_reto_home,c.p_reto_draw,c.p_reto_away))) desc,
      c.arranca_en,c.espn_event_id) as rn_deporte
  from c
)
select
  s.espn_event_id,s.deporte,s.liga,s.home,s.away,s.arranca_en,s.etiqueta_cuando,s.mercado,s.pick_nombre,s.pick_desc,s.probabilidad_pct,
  s.model_version,s.calibration_version,s.respaldo,s.momio_mercado,s.casa,s.es_lock,s.validado_fuera_de_muestra,s.rank_global,
  case when s.momio_mercado>1 then round(100.0/s.momio_mercado,1) end as prob_que_implica_el_precio_pct,
  33.3::numeric as base_azar,
  round(s.probabilidad_pct-33.3,1) as ventaja_sobre_azar,
  round(s.discriminacion_pp,1) as discriminacion_pp,
  least(s.sample_home,s.sample_away)::integer as muestra_calibracion,
  true as calibracion_confiable,
  null::integer as h2h_juegos,
  null::numeric as h2h_total_promedio,
  null::boolean as h2h_apoya,
  true as es_validado,
  null::text as advertencia,
  'P_RETO canonico · selector 1X2 argmax congelado · mercado solo contexto'::text as razon,
  ('Modelo '||s.model_version||' · OOS validado · diferencia vs segunda salida: '||round(s.discriminacion_pp,1)||' pp')::text as resumen,
  s.rn_deporte,
  s.canonical_pick_status,
  true as selector_authoritative,
  true as top_only_authoritative,
  'FROZEN'::text as rank_policy_status,
  s.canonical_pick_version
from scored s;

create or replace view public.v_soccer_publication_invariant_leaks as
select canonical_event_id,'MODEL_IDENTITY_MISMATCH'::text as leak
from public.v_futpro_publication_v3
where p_reto_home is not null and engine is distinct from model_version
union all
select canonical_event_id,'READY_WITHOUT_SELECTOR'
from public.v_futpro_publication_v3
where canonical_pick_status='READY' and selector_authoritative is distinct from true
union all
select canonical_event_id,'READY_BAD_DISTRIBUTION'
from public.v_futpro_publication_v3
where canonical_pick_status='READY' and abs((p_reto_home+p_reto_draw+p_reto_away)-100)>0.2
union all
select canonical_event_id,'READY_BAD_TEMPORALITY'
from public.v_futpro_publication_v3
where canonical_pick_status='READY'
  and (temporal_safe is distinct from true or data_asof>prediction_time or (computed_at is not null and prediction_time>computed_at))
union all
select espn_event_id,'RETO_NONAUTHORITATIVE'
from public.v_reto13m_lo_mejor
where canonical_pick_status<>'READY'
   or selector_authoritative is distinct from true
   or top_only_authoritative is distinct from true
   or rank_policy_status<>'FROZEN';
