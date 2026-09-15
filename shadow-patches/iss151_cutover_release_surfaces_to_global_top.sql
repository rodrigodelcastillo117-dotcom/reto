-- ISS151 — cut release-facing legacy surfaces over to Global TOP_ONLY authority.
-- Purpose: one brain / one P_RETO across old public contracts while frontend cutover finishes.
-- Market is diagnostic only. No research/challenger row can enter these views.

create or replace view public.v_mejor_pick_por_partido as
select
  g.espn_event_id,g.sport as deporte,g.league_name as liga,g.home_team as home,g.away_team as away,g.kickoff as arranca_en,
  case when g.dia_mx=(now() at time zone 'America/Mexico_City')::date then 'HOY '||to_char(g.kickoff at time zone 'America/Mexico_City','HH12:MI am') when g.dia_mx=(now() at time zone 'America/Mexico_City')::date+1 then 'MANANA '||to_char(g.kickoff at time zone 'America/Mexico_City','HH12:MI am') else to_char(g.kickoff at time zone 'America/Mexico_City','DD/MM - HH12:MI am') end as etiqueta_cuando,
  g.market as mercado,g.selection_label as pick_nombre,g.selection_label as pick_desc,g.p_reto_pct as probabilidad_pct,
  coalesce(a.live_n,case when s.sample_home is not null and s.sample_away is not null then least(s.sample_home,s.sample_away)::int end) as muestra_calibracion,
  true as calibracion_confiable,g.source_contract as fuente,'P_RETO oficial desde autoridad global; mercado solo contexto.'::text as razon,
  ('Modelo '||coalesce(g.model_version,'—')||' · '||coalesce(g.validation_status,'VALIDADO'))::text as resumen,
  case when lower(g.selection_label)=lower('Gana '||g.home_team) then o.home_ml when lower(g.selection_label)='empate' then o.draw_ml when lower(g.selection_label)=lower('Gana '||g.away_team) then o.away_ml else null end::numeric as momio_mercado,
  o.bookmaker as casa,o.snapshot_at as momio_capturado_at,g.model_version,g.validation_status as calibration_version,false as apto_para_lock,1::bigint as rank_en_partido
from public.v_reto13m_global_top_v2 g
left join lateral (select f.sample_home,f.sample_away from public.v_futpro_publication_v3 f where f.canonical_event_id=g.espn_event_id limit 1) s on true
left join lateral (select r.live_n from public.v_reto_brain_release_authority_v2 r where r.model_version=g.model_version and r.product_release_authorized order by r.updated_at desc nulls last limit 1) a on true
left join lateral (select x.home_ml,x.draw_ml,x.away_ml,x.bookmaker,x.snapshot_at from public.v_momios_confiables x where x.espn_event_id=g.espn_event_id and x.confiable order by x.snapshot_at desc limit 1) o on true;

create or replace view public.v_picks_con_valor as
select m.espn_event_id,m.deporte,m.liga,m.home,m.away,m.arranca_en,m.mercado,m.pick_desc,m.probabilidad_pct,m.momio_mercado,m.casa,case when m.probabilidad_pct>0 then round(100.0/m.probabilidad_pct,3) else null end::numeric as momio_justo,m.calibracion_confiable,m.muestra_calibracion from public.v_mejor_pick_por_partido m;

create or replace view public.v_reto13m_daily as
select g.sport as deporte,g.espn_event_id as canonical_event_id,g.home_team,g.away_team,g.league_name as competition_name,s.escudo_home,s.escudo_away,g.dia_mx,g.kickoff,g.selection_label as mejor_pick,g.p_reto_pct as mejor_pick_prob,s.predicted_score,s.predicted_score_prob,g.p_reto_pct as p_reto_lider,g.model_version,coalesce(a.live_n,case when s.sample_home is not null and s.sample_away is not null then least(s.sample_home,s.sample_away)::int end) as muestra_min,g.rank_dia,g.is_day_top_1 as es_mejor_del_dia
from public.v_reto13m_global_top_v2 g
left join lateral (select f.escudo_home,f.escudo_away,f.predicted_score,f.predicted_score_prob,f.sample_home,f.sample_away from public.v_futpro_publication_v3 f where f.canonical_event_id=g.espn_event_id limit 1) s on true
left join lateral (select r.live_n from public.v_reto_brain_release_authority_v2 r where r.model_version=g.model_version and r.product_release_authorized order by r.updated_at desc nulls last limit 1) a on true;

create or replace view public.v_reto13m_mejores as
select m.espn_event_id,m.deporte,m.liga,m.home,m.away,m.arranca_en,m.etiqueta_cuando,m.mercado,m.pick_nombre,m.pick_desc,m.probabilidad_pct as probabilidad_cruda_pct,m.model_version,m.calibration_version,m.momio_mercado,m.casa,false as es_lock,true as validado_fuera_de_muestra,g.rank_global,m.probabilidad_pct as probabilidad_pct
from public.v_mejor_pick_por_partido m join public.v_reto13m_global_top_v2 g using(espn_event_id);

create or replace view public.v_reto_editorial_pool_v2 as
select g.espn_event_id,g.sport as deporte,g.league_name as liga,g.home_team as home,g.away_team as away,g.kickoff as arranca_en,g.market as mercado,g.selection_label as pick_desc,g.p_reto_pct as probabilidad_pct,g.model_version,g.model_separation_pp as discriminacion_pp,g.rank_global,row_number() over(partition by g.sport order by g.rank_global)::bigint as rn_deporte,true as es_validado,true as selector_authoritative,true as top_only_authoritative,'FROZEN'::text as rank_policy_status,
case when lower(g.selection_label)='empate' then 'DRAW' when lower(g.selection_label)=lower('Gana '||g.home_team) then 'HOME' when lower(g.selection_label)=lower('Gana '||g.away_team) then 'AWAY' else null end::text as selected_side,
o.bookmaker,o.snapshot_at as odds_captured_at,o.home_ml,o.draw_ml,o.away_ml,
case when o.home_ml>1 and o.draw_ml>1 and o.away_ml>1 then case when lower(g.selection_label)='empate' then 100*(1/o.draw_ml)/(1/o.home_ml+1/o.draw_ml+1/o.away_ml) when lower(g.selection_label)=lower('Gana '||g.home_team) then 100*(1/o.home_ml)/(1/o.home_ml+1/o.draw_ml+1/o.away_ml) when lower(g.selection_label)=lower('Gana '||g.away_team) then 100*(1/o.away_ml)/(1/o.home_ml+1/o.draw_ml+1/o.away_ml) end when o.home_ml>1 and o.away_ml>1 then case when lower(g.selection_label)=lower('Gana '||g.home_team) then 100*(1/o.home_ml)/(1/o.home_ml+1/o.away_ml) when lower(g.selection_label)=lower('Gana '||g.away_team) then 100*(1/o.away_ml)/(1/o.home_ml+1/o.away_ml) end else null end::numeric as market_selected_novig_pct,
case when o.home_ml>1 and o.draw_ml>1 and o.away_ml>1 then case when o.home_ml<=o.draw_ml and o.home_ml<=o.away_ml then 'HOME' when o.draw_ml<=o.home_ml and o.draw_ml<=o.away_ml then 'DRAW' else 'AWAY' end when o.home_ml>1 and o.away_ml>1 then case when o.home_ml<=o.away_ml then 'HOME' else 'AWAY' end else null end::text as market_favorite_side,
case when g.p_reto_pct>=65 and coalesce(g.model_separation_pp,0)>=15 then 'ALTA' when g.p_reto_pct>=58 and coalesce(g.model_separation_pp,0)>=8 then 'MEDIA' else 'CAUTELOSA' end::text as confidence_band
from public.v_reto13m_global_top_v2 g
left join lateral (select x.home_ml,x.draw_ml,x.away_ml,x.bookmaker,x.snapshot_at from public.v_momios_confiables x where x.espn_event_id=g.espn_event_id and x.confiable order by x.snapshot_at desc limit 1) o on true;

create or replace view public.v_reto_parlay_candidate_pool_v2_fast as
select g.espn_event_id,g.sport,(g.sport||':'||coalesce(g.league_name,'GLOBAL'))::text as competition_scope,g.league_name as competition_name,g.home_team,g.away_team,g.kickoff,g.market,g.selection_label as pick,g.p_reto_pct,g.model_separation_pp as separation_pp,
case when g.p_reto_pct>=65 and coalesce(g.model_separation_pp,0)>=15 then 'ALTA' when g.p_reto_pct>=58 and coalesce(g.model_separation_pp,0)>=8 then 'MEDIA' else 'CAUTELOSA' end::text as confidence_band,
g.model_version,g.validation_status as calibration_version,'GLOBAL_TOP_V2'::text as canonical_pick_version,'READY'::text as canonical_pick_status,true as selector_authoritative,true as top_only_authoritative,'FROZEN'::text as rank_policy_status,true as scientific_ready,true as product_release_authorized,false as money_authorized,
case when lower(g.selection_label)=lower('Gana '||g.home_team) then o.home_ml when lower(g.selection_label)='empate' then o.draw_ml when lower(g.selection_label)=lower('Gana '||g.away_team) then o.away_ml end::numeric as selected_decimal_odds,
o.bookmaker as odds_bookmaker,
case when (case when lower(g.selection_label)=lower('Gana '||g.home_team) then o.home_ml when lower(g.selection_label)='empate' then o.draw_ml when lower(g.selection_label)=lower('Gana '||g.away_team) then o.away_ml end)>1 then round(100.0/(case when lower(g.selection_label)=lower('Gana '||g.home_team) then o.home_ml when lower(g.selection_label)='empate' then o.draw_ml when lower(g.selection_label)=lower('Gana '||g.away_team) then o.away_ml end),2) end::numeric as book_implied_raw_pct,
case when (case when lower(g.selection_label)=lower('Gana '||g.home_team) then o.home_ml when lower(g.selection_label)='empate' then o.draw_ml when lower(g.selection_label)=lower('Gana '||g.away_team) then o.away_ml end)>1 then round(g.p_reto_pct-100.0/(case when lower(g.selection_label)=lower('Gana '||g.home_team) then o.home_ml when lower(g.selection_label)='empate' then o.draw_ml when lower(g.selection_label)=lower('Gana '||g.away_team) then o.away_ml end),2) end::numeric as discrepancy_vs_book_raw_pp,
row_number() over(partition by g.sport order by g.rank_global)::bigint as rn_deporte,g.rank_global,'P_RETO oficial; selección global sin cuotas, EV ni cuotas por deporte.'::text as razon,true as canonical_leg
from public.v_reto13m_global_top_v2 g
left join lateral (select x.home_ml,x.draw_ml,x.away_ml,x.bookmaker,x.snapshot_at from public.v_momios_confiables x where x.espn_event_id=g.espn_event_id and x.confiable order by x.snapshot_at desc limit 1) o on true;
