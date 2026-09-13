-- ISS125 SOCCER REAL-PATH GATE — DISPOSABLE ONLY
-- builder -> staged -> event gate -> candidates -> dossier
-- Six real owner UCL fixtures, decision epoch strictly pre-kickoff.
-- Entire test rolls back.

begin;

-- Force real builder evidence: no preseeded staged rows may satisfy the gate.
delete from v2.soccer_prediction_v2_staged
where decision_time='2026-09-10 12:00:00+00'::timestamptz
  and espn_event_id in ('401915422','401915440','401915441','401915442','401915443','401915444');

select v2.build_soccer_prediction_v2_staged(
  '2026-09-10 12:00:00+00'::timestamptz,true,null) as built_count;

DO $$
DECLARE n int;
BEGIN
  select count(*) into n
  from v2.soccer_prediction_v2_staged
  where decision_time='2026-09-10 12:00:00+00'::timestamptz
    and espn_event_id in ('401915422','401915440','401915441','401915442','401915443','401915444')
    and model_version='crossleague_v1_1'
    and model_route='CROSSLEAGUE'
    and feature_version='domestic_form_phi_v1_1'
    and temporal_safe and availability_verified
    and feature_snapshot_id is not null
    and feature_data_asof<=decision_time
    and max_source_event_time<=decision_time
    and coalesce(provenance->>'engine','')='crossleague_v1_1'
    and coalesce((provenance->>'odds_price_used_in_p_reto')::boolean,false)=false;
  if n<>6 then raise exception 'SOCCER_REALPATH_FAIL staged=%/6',n; end if;

  select count(*) into n from (
    select espn_event_id,decision_time,count(*) c
    from v2.soccer_prediction_v2_staged
    where decision_time='2026-09-10 12:00:00+00'::timestamptz
      and espn_event_id in ('401915422','401915440','401915441','401915442','401915443','401915444')
    group by 1,2 having count(*)<>1
  ) q;
  if n<>0 then raise exception 'SOCCER_REALPATH_FAIL multiple canonical brains=%',n; end if;

  select count(*) into n
  from v2.v_soccer_crossleague_authority_violations
  where espn_event_id in ('401915422','401915440','401915441','401915442','401915443','401915444');
  if n<>0 then raise exception 'SOCCER_REALPATH_FAIL authority violations=%',n; end if;

  select count(*) into n
  from v2.v_soccer_event_gate
  where canonical_event_id in ('401915422','401915440','401915441','401915442','401915443','401915444')
    and decision_time='2026-09-10 12:00:00+00'::timestamptz
    and model_version='crossleague_v1_1' and coherence_ok;
  if n<>6 then raise exception 'SOCCER_REALPATH_FAIL event_gate=%/6',n; end if;

  select count(distinct canonical_event_id) into n
  from v2.v_soccer_daily_candidates
  where canonical_event_id in ('401915422','401915440','401915441','401915442','401915443','401915444')
    and decision_time='2026-09-10 12:00:00+00'::timestamptz
    and model_version='crossleague_v1_1';
  if n<>6 then raise exception 'SOCCER_REALPATH_FAIL candidates=%/6',n; end if;

  with ids(event_id) as (
    values ('401915422'),('401915440'),('401915441'),('401915442'),('401915443'),('401915444')
  ), q as (
    select i.event_id,
           bool_or(d.source_name='modelo_p_reto' and d.available and d.used_in_p_reto
                   and d.temporally_safe and d.feature_snapshot_id is not null
                   and d.feature_version='domestic_form_phi_v1_1'
                   and d.provenance like '%model_version=crossleague_v1_1%') ok
    from ids i
    cross join lateral v2.fn_soccer_dossier_manifest(
      i.event_id,'2026-09-10 12:00:00+00'::timestamptz) d
    group by i.event_id
  )
  select count(*) into n from q where ok;
  if n<>6 then raise exception 'SOCCER_REALPATH_FAIL dossier=%/6',n; end if;
END $$;

-- Price invariance: odds may affect economics/gate diagnostics, never canonical P_RETO.
create temporary table _soccer_before_price on commit drop as
select espn_event_id,p_home,p_draw,p_away,btts_yes,btts_no,p_over,p_under,p_push,over_line,score_dist
from v2.soccer_prediction_v2_staged
where decision_time='2026-09-10 12:00:00+00'::timestamptz
  and espn_event_id in ('401915422','401915440','401915441','401915442','401915443','401915444')
  and model_version='crossleague_v1_1';

update public.v_momios_confiables
set home_ml=coalesce(home_ml,2)*1.77, draw_ml=coalesce(draw_ml,3)*1.61,
    away_ml=coalesce(away_ml,2)*1.83, over_odds=coalesce(over_odds,2)*1.91,
    under_odds=coalesce(under_odds,2)*1.57
where espn_event_id in ('401915422','401915440','401915441','401915442','401915443','401915444')
  and snapshot_at<='2026-09-10 12:00:00+00'::timestamptz;

select v2.build_soccer_prediction_v2_staged(
  '2026-09-10 12:00:00+00'::timestamptz,true,null) as rebuilt_after_price_mutation;

DO $$
DECLARE n int;
BEGIN
  select count(*) into n
  from v2.soccer_prediction_v2_staged a
  join _soccer_before_price b using (espn_event_id)
  where a.decision_time='2026-09-10 12:00:00+00'::timestamptz
    and a.model_version='crossleague_v1_1'
    and row(a.p_home,a.p_draw,a.p_away,a.btts_yes,a.btts_no,a.p_over,a.p_under,a.p_push,a.over_line,a.score_dist)
        is distinct from
        row(b.p_home,b.p_draw,b.p_away,b.btts_yes,b.btts_no,b.p_over,b.p_under,b.p_push,b.over_line,b.score_dist);
  if n<>0 then raise exception 'SOCCER_PRICE_INVARIANCE_FAIL changed=%',n; end if;
END $$;

-- Ambiguous second brain must fail closed in dossier.
insert into v2.soccer_prediction_v2_staged
select s.espn_event_id,s.competition_id,s.home_team,s.away_team,s.kickoff,s.decision_time,
       s.feature_data_asof,s.max_source_event_time,s.sample_home,s.sample_away,s.temporal_safe,
       s.feature_version,'audit_conflicting_brain',s.calibration_status,
       s.p_home,s.p_draw,s.p_away,s.btts_yes,s.btts_no,s.over_line,s.p_over,s.p_under,
       s.line_source,s.line_asof,s.model_status,s.model_status_reason,s.provenance,
       s.competition_mapping_version,s.availability_verified,s.score_dist,s.top_scores,
       s.p_push,s.ou_line_type,s.ou_supported,s.feature_snapshot_id,now(),s.model_name,s.model_route
from v2.soccer_prediction_v2_staged s
where s.espn_event_id='401915422'
  and s.decision_time='2026-09-10 12:00:00+00'::timestamptz
  and s.model_version='crossleague_v1_1';

DO $$
DECLARE r record;
BEGIN
  select * into r from v2.fn_soccer_dossier_manifest(
    '401915422','2026-09-10 12:00:00+00'::timestamptz) limit 1;
  if r.freshness_status is distinct from 'AMBIGUOUS_CANONICAL_STAGED'
     or coalesce(r.available,true) or coalesce(r.used_in_p_reto,true) then
    raise exception 'SOCCER_AMBIGUITY_FAIL dossier did not fail closed';
  end if;
END $$;

rollback;
