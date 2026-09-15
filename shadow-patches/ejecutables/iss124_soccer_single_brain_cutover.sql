-- =====================================================================
-- ISS124 · SOCCER SINGLE-BRAIN CUTOVER
-- =====================================================================
-- OWNER CONTRACT:
--   ONE BRAIN · ONE ANALYSIS · ONE MATRIX · ONE USER-VISIBLE P_RETO.
--
-- ROOT CAUSE FOUND 2026-09-14:
--   cron job v2_build_soccer_prediction calls v2.build_soccer_prediction_v2().
--   That function selected between TWO probability engines:
--     1) v2.fn_crossleague_predict_canonical() for PROD_APPROVED policies
--     2) reto_dc_v2 / v_goles_equipo_futbol + fn_score_dist fallback otherwise
--   Therefore one public table hid two independent probability authorities.
--
-- FIX:
--   v2.fn_crossleague_predict_canonical becomes the ONLY soccer probability
--   authority. It already supports SAME_LEAGUE (phi cancels) and CROSS_LEAGUE
--   modes under one sealed model registry / one joint score distribution.
--   Unsupported/unapproved competitions FAIL CLOSED with no P_RETO.
--
-- IMPORTANT:
--   Odds remain context/line only. They never manufacture P_RETO.
--   Historical rows are not rewritten. This is a serving cutover only.
-- =====================================================================

create or replace function v2.build_soccer_prediction_v2()
returns integer
language plpgsql
as $function$
declare n int;
begin
  with upcoming as (
    select distinct on (a.espn_event_id)
      a.espn_event_id,a.liga_id,a.liga_nombre,a.home_nombre,a.away_nombre,a.fecha,
      a.home_espn_id,a.away_espn_id
    from public.agenda_espn a
    where a.deporte='soccer' and a.fecha>now()
      and a.home_nombre is not null and a.away_nombre is not null and a.liga_id is not null
    order by a.espn_event_id,a.fecha
  ), odds as (
    select distinct on (espn_event_id) espn_event_id,over_line,over_odds,under_odds,
      home_ml,draw_ml,away_ml,bookmaker,snapshot_at
    from public.v_momios_confiables
    where espn_event_id is not null and snapshot_at<=now()
    order by espn_event_id,snapshot_at desc
  ), calc as (
    select u.*,la.competition_id,
      o.over_line,o.over_odds,o.under_odds,o.home_ml,o.draw_ml,o.away_ml,o.bookmaker,o.snapshot_at,
      x.p_home,x.p_draw,x.p_away,x.btts_yes,x.btts_no,x.p_over,x.p_under,
      x.lambda_home,x.lambda_away,x.exp_goals_total,x.predicted_score,x.predicted_score_prob,x.score_dist,
      x.model_status,x.model_status_reason,x.data_asof,x.sample_home,x.sample_away,x.provenance
    from upcoming u
    left join v2.liga_alias la on la.liga_source=u.liga_nombre
    left join odds o on o.espn_event_id=u.espn_event_id
    left join lateral v2.fn_crossleague_predict_canonical(
      u.home_espn_id,u.away_espn_id,now(),la.competition_id,o.over_line
    ) x on true
  )
  insert into v2.soccer_prediction_v2(
    espn_event_id,competition_id,home_team,away_team,kickoff,
    model_name,model_version,feature_version,calibration_status,
    data_asof,prediction_time,sample_home,sample_away,temporal_safe,
    lambda_home,lambda_away,exp_goals_total,p_home,p_draw,p_away,btts_yes,btts_no,
    over_line,p_over,p_under,line_source,predicted_score,predicted_score_prob,score_dist,
    odds_home,odds_draw,odds_away,odds_over,odds_under,odds_bookmaker,odds_captured_at,
    model_status,model_status_reason,provenance,computed_at
  )
  select
    espn_event_id,competition_id,home_nombre,away_nombre,fecha,
    'reto_soccer_canonical'::text,
    coalesce(provenance->>'engine','NO_MODEL')::text,
    'soccer_single_brain_v1'::text,
    coalesce(provenance->>'validation_status','UNVALIDATED')::text,
    data_asof,now(),sample_home,sample_away,
    (model_status='READY_UNVALIDATED' and data_asof is not null and data_asof<=now()),
    case when model_status='READY_UNVALIDATED' then lambda_home end,
    case when model_status='READY_UNVALIDATED' then lambda_away end,
    case when model_status='READY_UNVALIDATED' then exp_goals_total end,
    case when model_status='READY_UNVALIDATED' then p_home end,
    case when model_status='READY_UNVALIDATED' then p_draw end,
    case when model_status='READY_UNVALIDATED' then p_away end,
    case when model_status='READY_UNVALIDATED' then btts_yes end,
    case when model_status='READY_UNVALIDATED' then btts_no end,
    over_line,
    case when model_status='READY_UNVALIDATED' then p_over end,
    case when model_status='READY_UNVALIDATED' then p_under end,
    case when over_line is not null then 'v_momios_confiables:'||coalesce(bookmaker,'?') end,
    case when model_status='READY_UNVALIDATED' then predicted_score end,
    case when model_status='READY_UNVALIDATED' then predicted_score_prob end,
    case when model_status='READY_UNVALIDATED' then score_dist end,
    home_ml,draw_ml,away_ml,over_odds,under_odds,bookmaker,snapshot_at,
    coalesce(model_status,'DATA_INCOMPLETE'),
    case
      when competition_id is null then 'NO_CANONICAL_COMPETITION_MAPPING: fail-closed; no secondary soccer brain'
      else coalesce(model_status_reason,'CANONICAL_SOCCER_MODEL_NOT_READY')
    end,
    coalesce(provenance,'{}'::jsonb) || jsonb_build_object(
      'brain','SOCCER_CANONICAL_ONE',
      'single_probability_authority',true,
      'secondary_probability_fallback',false,
      'event_liga_id',liga_id,
      'competition_id',competition_id,
      'odds_context','v_momios_confiables',
      'odds_is_context_not_preto',true,
      'line_source',bookmaker,
      'line_asof',snapshot_at
    ),
    now()
  from calc;

  get diagnostics n=row_count;
  return n;
end
$function$;

comment on function v2.build_soccer_prediction_v2() is
'ISS124. SINGLE BRAIN soccer serving. Only fn_crossleague_predict_canonical may create soccer P_RETO. SAME_LEAGUE is handled by the same engine with phi=0; cross-league uses sealed phi. Unsupported/unapproved competitions fail closed. No reto_dc_v2 probability fallback.';

-- Latest-row audit: history may contain pre-cutover engines; only the newest
-- serving row for each event is judged.
create or replace function v2.gate_soccer_single_brain()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable
as $gate$
with latest as (
  select distinct on (espn_event_id)
    espn_event_id,model_name,model_version,feature_version,model_status,
    p_home,p_draw,p_away,provenance,computed_at
  from v2.soccer_prediction_v2
  order by espn_event_id,computed_at desc nulls last,prediction_time desc nulls last
), ready as (
  select * from latest
  where model_status='READY_UNVALIDATED'
     or p_home is not null or p_draw is not null or p_away is not null
)
select 'SOCCER_ONE_BRAIN_LATEST'::text,
       case when count(*) filter (where model_name is distinct from 'reto_soccer_canonical')=0 then 'PASS' else 'FAIL' end,
       count(*) filter (where model_name is distinct from 'reto_soccer_canonical'),
       'latest actionable soccer rows not owned by reto_soccer_canonical'::text
from ready
union all
select 'SOCCER_NO_SECONDARY_FALLBACK'::text,
       case when count(*) filter (where coalesce((provenance->>'secondary_probability_fallback')::boolean,true))=0 then 'PASS' else 'FAIL' end,
       count(*) filter (where coalesce((provenance->>'secondary_probability_fallback')::boolean,true)),
       'latest actionable rows must explicitly declare secondary_probability_fallback=false'::text
from ready
union all
select 'SOCCER_1X2_COMPLETE_OR_NULL'::text,
       case when count(*)=0 then 'PASS' else 'FAIL' end,
       count(*),
       'partial 1X2 vectors are forbidden'::text
from latest
where (p_home is null)::int + (p_draw is null)::int + (p_away is null)::int not in (0,3);
$gate$;

comment on function v2.gate_soccer_single_brain() is
'ISS124. Audits latest soccer serving row per event: one canonical brain, no secondary fallback, no partial 1X2 vector.';

grant execute on function v2.gate_soccer_single_brain() to authenticated,service_role;

-- No cron edit is required: job v2_build_soccer_prediction already calls
-- v2.build_soccer_prediction_v2(), so replacing this function is the cutover.
