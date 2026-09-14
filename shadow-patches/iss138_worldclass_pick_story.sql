-- ISS138 — World-class Pick Story contract
-- Lightweight card view + on-demand detailed dossier.
-- Soccer 1X2 only for now because it is the only cross-sport prediction surface with explicit product selector authority.
-- Context never overrides P_RETO. Market/no-vig never becomes the prediction. BTTS/OU are not published here until separately release-authorized.

create or replace view public.v_reto_pick_story_cards_v1 as
with b as (
  select f.*,
    case when f.odds_home>1 and f.odds_draw>1 and f.odds_away>1
      then (1/f.odds_home)+(1/f.odds_draw)+(1/f.odds_away) end as inv_sum
  from public.v_futpro_publication_v3 f
  where f.canonical_pick_status='READY' and f.selector_authoritative
), x as (
  select b.*,
    case when b.canonical_pick_prob=b.p_reto_home then 'HOME'
         when b.canonical_pick_prob=b.p_reto_draw then 'DRAW'
         when b.canonical_pick_prob=b.p_reto_away then 'AWAY' end as selected_side,
    case when b.inv_sum is not null and b.canonical_pick_prob=b.p_reto_home then 100*(1/b.odds_home)/b.inv_sum
         when b.inv_sum is not null and b.canonical_pick_prob=b.p_reto_draw then 100*(1/b.odds_draw)/b.inv_sum
         when b.inv_sum is not null and b.canonical_pick_prob=b.p_reto_away then 100*(1/b.odds_away)/b.inv_sum end as market_selected_pct
  from b
), ranked as (
  select x.*,
    case x.selected_side
      when 'HOME' then case when x.p_reto_draw>=x.p_reto_away then 'Empate' else 'Gana '||x.away_team end
      when 'DRAW' then case when x.p_reto_home>=x.p_reto_away then 'Gana '||x.home_team else 'Gana '||x.away_team end
      when 'AWAY' then case when x.p_reto_home>=x.p_reto_draw then 'Gana '||x.home_team else 'Empate' end
    end as second_outcome,
    case x.selected_side
      when 'HOME' then greatest(x.p_reto_draw,x.p_reto_away)
      when 'DRAW' then greatest(x.p_reto_home,x.p_reto_away)
      when 'AWAY' then greatest(x.p_reto_home,x.p_reto_draw)
    end as second_outcome_pct
  from x
)
select r.canonical_event_id as espn_event_id,r.competition_id,r.competition_name,r.group_name,r.display_order,
  r.home_team,r.away_team,r.kickoff,r.event_status,r.escudo_home,r.escudo_away,
  r.canonical_market,r.canonical_pick,r.canonical_pick_prob as p_reto_pct,r.selected_side,
  r.p_reto_home,r.p_reto_draw,r.p_reto_away,r.second_outcome,r.second_outcome_pct,
  round((r.canonical_pick_prob-r.second_outcome_pct)::numeric,2) as separation_pp,
  round(r.market_selected_pct::numeric,2) as market_novig_pct,
  round((r.canonical_pick_prob-r.market_selected_pct)::numeric,2) as discrepancy_vs_market_pp,
  r.odds_bookmaker,r.odds_captured_at,
  case when r.canonical_pick_prob>=70 and (r.canonical_pick_prob-r.second_outcome_pct)>=20 then 'ALTA'
       when r.canonical_pick_prob>=58 and (r.canonical_pick_prob-r.second_outcome_pct)>=12 then 'MEDIA'
       else 'CAUTELOSA' end::text as confidence_band,
  'Banda descriptiva, no una probabilidad nueva: ALTA=P_RETO>=70 y separacion>=20pp; MEDIA=P_RETO>=58 y separacion>=12pp; resto=CAUTELOSA.'::text as confidence_basis,
  r.predicted_score,r.predicted_score_prob,r.score_dist,r.score_available,
  r.model_name,r.model_version,r.feature_version,r.calibration_status,r.temporal_safe,r.data_asof,r.prediction_time,r.computed_at,
  r.selector_version,r.canonical_pick_version,r.canonical_pick_reason,r.publication_lineage,
  a.scientific_ready,a.product_release_authorized,a.money_authorized,a.release_status,a.validation_status,a.live_status,a.live_n,
  a.live_brier_model,a.live_brier_reference,a.live_calibration_gap_pp,a.live_accuracy_pct,a.reason as authority_reason,
  prev.prediction_time as previous_snapshot_at,
  round((r.canonical_pick_prob - case r.selected_side when 'HOME' then prev.p_home when 'DRAW' then prev.p_draw else prev.p_away end)::numeric,2) as change_vs_previous_pp,
  dayago.prediction_time as approx_24h_snapshot_at,
  round((r.canonical_pick_prob - case r.selected_side when 'HOME' then dayago.p_home when 'DRAW' then dayago.p_draw else dayago.p_away end)::numeric,2) as change_vs_24h_pp,
  case when r.market_selected_pct is null then 'SIN_MERCADO'
       when abs(r.canonical_pick_prob-r.market_selected_pct)<2 then 'ALINEADO'
       when r.canonical_pick_prob>r.market_selected_pct then 'RETO_MAS_ALTO'
       else 'MERCADO_MAS_ALTO' end::text as market_disagreement_direction
from ranked r
join public.v_reto_brain_release_authority_v1 a
  on a.sport='soccer' and a.league_scope='competition:'||r.competition_id and a.market='1X2' and a.model_version=r.model_version
left join lateral (
  select p.prediction_time,p.p_home,p.p_draw,p.p_away
  from v2.soccer_prediction_v2 p
  where p.espn_event_id=r.canonical_event_id and p.model_version=r.model_version and p.prediction_time<r.prediction_time and p.temporal_safe
  order by p.prediction_time desc limit 1
) prev on true
left join lateral (
  select p.prediction_time,p.p_home,p.p_draw,p.p_away
  from v2.soccer_prediction_v2 p
  where p.espn_event_id=r.canonical_event_id and p.model_version=r.model_version
    and p.prediction_time<=r.prediction_time-interval '20 hours' and p.temporal_safe
  order by p.prediction_time desc limit 1
) dayago on true
where a.product_release_authorized and a.scientific_ready;

comment on view public.v_reto_pick_story_cards_v1 is
'Canonical Pick Story card contract. P_RETO is model-owned; no-vig market is diagnostic. Secondary soccer markets are intentionally absent until independently release-authorized.';

grant select on public.v_reto_pick_story_cards_v1 to anon,authenticated;

create or replace function public.reto_pick_story_v1(p_espn_event_id text)
returns jsonb
language plpgsql
stable security definer
set search_path='public','v2','extensions','pg_temp'
as $$
declare
  c record;
  f record;
  d jsonb;
  caveats jsonb := '[]'::jsonb;
  expl text;
  change_text text;
begin
  select * into c from public.v_reto_pick_story_cards_v1 where espn_event_id=p_espn_event_id limit 1;

  if c.espn_event_id is null then
    select * into f from public.v_futpro_publication_v3 where canonical_event_id=p_espn_event_id limit 1;
    if f.canonical_event_id is null then
      return jsonb_build_object('ok',false,'status','EVENT_NOT_FOUND','espn_event_id',p_espn_event_id);
    end if;
    return jsonb_build_object(
      'ok',true,'status','NO_OFFICIAL_PICK','espn_event_id',p_espn_event_id,
      'home_team',f.home_team,'away_team',f.away_team,'kickoff',f.kickoff,
      'model_status',f.model_status,'model_status_reason',f.model_status_reason,
      'canonical_pick_status',f.canonical_pick_status,
      'reason',coalesce(f.canonical_pick_reason,'RETO no tiene una seleccion 1X2 autorizada para este evento.'));
  end if;

  d := public.construir_dossier_partido_base(p_espn_event_id,null);

  if coalesce((d#>>'{calidad_datos,tiene_alineaciones}')::boolean,false)=false then
    caveats := caveats || jsonb_build_array('XI todavía no confirmado; no se inventa alineación.');
  end if;
  if coalesce((d#>>'{calidad_datos,tiene_h2h}')::boolean,false)=false then
    caveats := caveats || jsonb_build_array('Sin H2H suficiente en la fuente factual.');
  end if;
  if c.market_novig_pct is null then
    caveats := caveats || jsonb_build_array('Sin mercado no-vig confiable para comparación; P_RETO permanece independiente.');
  elsif abs(c.discrepancy_vs_market_pp)>=8 then
    caveats := caveats || jsonb_build_array(format('RETO y mercado difieren %s pp; se muestra la discrepancia, pero el mercado no reemplaza P_RETO.',abs(c.discrepancy_vs_market_pp)));
  end if;
  if c.live_status is not null and c.live_status<>'PREDICTION_GATE_PASS' then
    caveats := caveats || jsonb_build_array(format('Monitoreo live del modelo: %s (n=%s). La autoridad release proviene de validación OOS sellada, no de esta muestra corta.',c.live_status,coalesce(c.live_n,0)));
  end if;

  expl := format('RETO da %s%% a %s. La segunda salida más probable es %s con %s%%: separación %s pp.',
    c.p_reto_pct,c.canonical_pick,c.second_outcome,c.second_outcome_pct,c.separation_pp);
  if c.market_novig_pct is not null then
    expl := expl || format(' El mercado sin vig está en %s%% para el mismo lado (%s pp vs RETO). El mercado es contexto, no modifica P_RETO.',
      c.market_novig_pct,c.discrepancy_vs_market_pp);
  end if;

  change_text := case
    when c.change_vs_24h_pp is not null then format('Desde la foto comparable de ~24h, el mismo lado cambió %s pp.',c.change_vs_24h_pp)
    when c.change_vs_previous_pp is not null then format('Desde el snapshot anterior, el mismo lado cambió %s pp.',c.change_vs_previous_pp)
    else 'Aún no hay una foto pregame anterior comparable para medir cambio.' end;

  return jsonb_build_object(
    'ok',true,'status','READY','contract_version','pick_story_v1',
    'event',jsonb_build_object('espn_event_id',c.espn_event_id,'competition_id',c.competition_id,'competition_name',c.competition_name,
      'home_team',c.home_team,'away_team',c.away_team,'kickoff',c.kickoff,'event_status',c.event_status,
      'home_logo',c.escudo_home,'away_logo',c.escudo_away),
    'prediction',jsonb_build_object('market',c.canonical_market,'pick',c.canonical_pick,'p_reto_pct',c.p_reto_pct,
      'distribution_1x2',jsonb_build_object('home',c.p_reto_home,'draw',c.p_reto_draw,'away',c.p_reto_away),
      'confidence_band',c.confidence_band,'confidence_basis',c.confidence_basis,
      'second_outcome',c.second_outcome,'second_outcome_pct',c.second_outcome_pct,'separation_pp',c.separation_pp,
      'model_version',c.model_version,'feature_version',c.feature_version,'selector_version',c.selector_version,
      'prediction_time',c.prediction_time,'data_asof',c.data_asof),
    'market_context',jsonb_build_object('available',c.market_novig_pct is not null,'bookmaker',c.odds_bookmaker,'captured_at',c.odds_captured_at,
      'same_side_novig_pct',c.market_novig_pct,'discrepancy_pp',c.discrepancy_vs_market_pp,'direction',c.market_disagreement_direction,
      'role','DIAGNOSTIC_ECONOMIC_ONLY','money_authorized',c.money_authorized),
    'what_changed',jsonb_build_object('previous_snapshot_at',c.previous_snapshot_at,'change_vs_previous_pp',c.change_vs_previous_pp,
      'approx_24h_snapshot_at',c.approx_24h_snapshot_at,'change_vs_24h_pp',c.change_vs_24h_pp,'summary',change_text),
    'what_could_go_wrong',jsonb_build_object('primary_alternative',c.second_outcome,'primary_alternative_pct',c.second_outcome_pct,'caveats',caveats),
    'simple_explanation',expl,
    'score_distribution',case when c.score_available then jsonb_build_object('status','MODEL_DISTRIBUTION','most_likely',c.predicted_score,
      'most_likely_pct',c.predicted_score_prob,'distribution',c.score_dist) else jsonb_build_object('status','UNAVAILABLE') end,
    'secondary_markets',jsonb_build_object('status','NOT_RELEASE_AUTHORIZED','note','BTTS/totales no se presentan como picks oficiales hasta pasar un gate científico propio.'),
    'context',jsonb_build_object(
      'recent_form',jsonb_build_object('home',d#>'{tendencias,local,ultimos}','away',d#>'{tendencias,visita,ultimos}'),
      'trend_context',d->'tendencias','h2h',coalesce(d->'h2h',d#>'{tendencias,h2h}'),
      'injuries',jsonb_build_object('home',d#>'{equipo_local,bajas}','away',d#>'{equipo_visitante,bajas}'),
      'lineups',jsonb_build_object('home',d#>'{equipo_local,alineacion}','away',d#>'{equipo_visitante,alineacion}'),
      'schedule',d->'contexto_calendario','line_movement',d->'movimiento_linea',
      'data_quality',d->'calidad_datos'),
    'authority',jsonb_build_object('scientific_ready',c.scientific_ready,'product_release_authorized',c.product_release_authorized,
      'money_authorized',c.money_authorized,'release_status',c.release_status,'validation_status',c.validation_status,
      'live_status',c.live_status,'live_n',c.live_n,'authority_reason',c.authority_reason),
    'principles',jsonb_build_object('one_brain',true,'market_can_override_p_reto',false,'unknown_fields_are_invented',false));
end $$;

grant execute on function public.reto_pick_story_v1(text) to anon,authenticated;

create or replace view public.v_reto_pick_story_invariant_leaks_v1 as
select c.espn_event_id,'AUTHORITY_MISMATCH'::text leak
from public.v_reto_pick_story_cards_v1 c
where not c.scientific_ready or not c.product_release_authorized
union all
select c.espn_event_id,'CANONICAL_LEADER_MISMATCH'
from public.v_reto_pick_story_cards_v1 c
where c.p_reto_pct<>greatest(c.p_reto_home,c.p_reto_draw,c.p_reto_away)
union all
select c.espn_event_id,'BAD_DISTRIBUTION'
from public.v_reto_pick_story_cards_v1 c
where abs((c.p_reto_home+c.p_reto_draw+c.p_reto_away)-100)>0.2
union all
select c.espn_event_id,'TEMPORAL_UNSAFE'
from public.v_reto_pick_story_cards_v1 c
where not c.temporal_safe or c.data_asof>c.prediction_time or c.prediction_time>=c.kickoff;

grant select on public.v_reto_pick_story_invariant_leaks_v1 to authenticated;
