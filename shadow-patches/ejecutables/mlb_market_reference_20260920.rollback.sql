-- Reversible rollback for Supabase migration 20260920193551.
-- Restore the previous scoring/gate behavior. Preserve v2.mlb_market_reference,
-- v2.v_model_learning_with_reference and v2.refresh_mlb_market_reference as
-- inaccessible audit objects; do not delete historical evidence.
begin;
CREATE OR REPLACE FUNCTION v2.refresh_model_learning_gates()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'v2', 'public', 'pg_temp'
AS $function$
declare n int;
begin
  delete from v2.model_learning_gate;
  with b as (
    select s.*,(s.brier_model-s.brier_naive) d_naive,
           case when s.brier_ref is not null then s.brier_model-s.brier_ref end d_ref,
           width_bucket(s.confidence,0.0,1.000001,10) cbucket
    from v2.v_model_learning_scored s where s.temporal_safe and s.promotion_eligible
  ), e as (
    select b.*,'GLOBAL'::text scope,'GLOBAL'::text league_scope from b
    union all select b.*,'LEAGUE',coalesce(b.league,'UNKNOWN') from b
  ), a as (
    select sport,scope,league_scope,market,model_version,eval_window,count(*)::int n_events,count(brier_ref)::int n_ref,
      avg(brier_model) bm,avg(brier_naive) bn,avg(brier_ref) br,avg(d_naive) dn,
      case when count(*)>1 then avg(d_naive)+1.96*stddev_samp(d_naive)/sqrt(count(*)) end dn95,
      avg(d_ref) dr,case when count(d_ref)>1 then avg(d_ref)+1.96*stddev_samp(d_ref)/sqrt(count(d_ref)) end dr95,
      avg(logloss_model) llm,avg(logloss_ref) llr,100*avg(case when leader_correct then 1.0 else 0 end) hit,
      100*avg(confidence) conf,100*count(brier_ref)::numeric/nullif(count(*),0) mcov
    from e group by 1,2,3,4,5,6
  ), cg as (
    select sport,scope,league_scope,market,model_version,eval_window,cbucket,count(*)::int bucket_n,
      100*abs(avg(case when leader_correct then 1.0 else 0 end)-avg(confidence)) gap
    from e group by 1,2,3,4,5,6,7
  ), cm as (
    select sport,scope,league_scope,market,model_version,eval_window,
      coalesce(max(gap) filter(where bucket_n>=20),max(gap)) maxgap,
      count(*) filter(where bucket_n>=20)::int supported_buckets
    from cg group by 1,2,3,4,5,6
  )
  insert into v2.model_learning_gate
    (sport,scope,league,market,model_version,eval_window,n_events,n_market_ref,brier_model,brier_naive,brier_market,
     brier_vs_naive_diff,brier_vs_naive_upper95,brier_vs_market_diff,brier_vs_market_upper95,logloss_model,logloss_market,
     leader_accuracy_pct,avg_confidence_pct,max_calibration_gap_pp,market_coverage_pct,prediction_authorized,money_authorized,
     lifecycle_stage,status,reason,computed_at)
  select a.sport,a.scope,a.league_scope,a.market,a.model_version,a.eval_window,a.n_events,a.n_ref,
    round(a.bm::numeric,6),round(a.bn::numeric,6),round(a.br::numeric,6),round(a.dn::numeric,6),round(a.dn95::numeric,6),round(a.dr::numeric,6),round(a.dr95::numeric,6),
    round(a.llm::numeric,6),round(a.llr::numeric,6),round(a.hit::numeric,2),round(a.conf::numeric,2),round(cm.maxgap::numeric,2),round(a.mcov::numeric,2),
    (a.scope='GLOBAL' and a.n_events>=coalesce(p.min_events_prediction,200) and coalesce(a.dn95,999)<0
      and coalesce(cm.maxgap,999)<=coalesce(p.max_calibration_gap_pp,7.5)),
    (a.scope='GLOBAL' and a.n_events>=coalesce(p.min_events_money,400) and coalesce(a.dn95,999)<0
      and coalesce(cm.maxgap,999)<=coalesce(p.max_calibration_gap_pp,7.5)
      and a.mcov>=coalesce(p.min_market_coverage_pct,75) and coalesce(a.dr95,999)<0),
    case when a.scope='LEAGUE' then 'LEAGUE_DIAGNOSTIC'
         when a.n_events<coalesce(p.min_events_prediction,200) then 'TEMPORAL_SAFE'
         when coalesce(a.dn95,999)>=0 then 'OOS_FAIL'
         when coalesce(cm.maxgap,999)>coalesce(p.max_calibration_gap_pp,7.5) then 'OOS_SKILL'
         when a.n_events>=coalesce(p.min_events_money,400) and a.mcov>=coalesce(p.min_market_coverage_pct,75) and coalesce(a.dr95,999)<0 then 'LOCK_READY'
         else 'CALIBRATION_VALID' end,
    case when a.scope='LEAGUE' and a.n_events<20 then 'INSUFFICIENT_LEAGUE_SAMPLE'
         when a.scope='GLOBAL' and a.n_events<coalesce(p.min_events_prediction,200) then 'INSUFFICIENT_SAMPLE'
         when a.scope='GLOBAL' and coalesce(a.dn95,999)>=0 then 'NO_OOS_SKILL'
         when a.scope='GLOBAL' and coalesce(cm.maxgap,999)>coalesce(p.max_calibration_gap_pp,7.5) then 'CALIBRATION_FAIL'
         when a.scope='GLOBAL' and a.n_events>=coalesce(p.min_events_money,400) and a.mcov>=coalesce(p.min_market_coverage_pct,75) and coalesce(a.dr95,999)<0 then 'MONEY_GATE_PASS'
         when a.scope='GLOBAL' then 'PREDICTION_GATE_PASS' else 'DIAGNOSTIC' end,
    case when a.scope='GLOBAL' and a.n_events<coalesce(p.min_events_prediction,200) then format('OOS %s/%s',a.n_events,coalesce(p.min_events_prediction,200))
         when a.scope='GLOBAL' and coalesce(a.dn95,999)>=0 then 'Sin mejora estadisticamente demostrada vs baseline.'
         when a.scope='GLOBAL' and coalesce(cm.maxgap,999)>coalesce(p.max_calibration_gap_pp,7.5) then format('Gap calibracion %s pp en buckets con soporte (n>=20).',round(cm.maxgap::numeric,2))
         when a.scope='GLOBAL' then format('Prediccion puede graduarse; calibracion usa buckets con soporte n>=20 (%s buckets). Dinero exige evidencia adicional contra mercado.',cm.supported_buckets)
         else 'Diagnostico por liga; nunca publica por si solo.' end,now()
  from a join cm using(sport,scope,league_scope,market,model_version,eval_window)
  left join v2.model_learning_policy p on p.sport=a.sport and p.market=a.market;
  get diagnostics n=row_count;
  return n;
end $function$
;
create or replace view v2.v_model_learning_scored as  SELECT observation_id,
    source_system,
    source_key,
    espn_event_id,
    sport,
    league,
    market,
    model_version,
    feature_version,
    eval_window,
    snapshot_at,
    kickoff,
    temporal_safe,
    promotion_eligible,
    n_classes,
    p1,
    p2,
    p3,
    ref1,
    ref2,
    ref3,
    outcome_idx,
    line,
    score_home,
    score_away,
    meta,
    created_at,
        CASE
            WHEN n_classes = 2 THEN power(p1 -
            CASE
                WHEN outcome_idx = 1 THEN 1
                ELSE 0
            END::numeric, 2::numeric) + power(p2 -
            CASE
                WHEN outcome_idx = 2 THEN 1
                ELSE 0
            END::numeric, 2::numeric)
            ELSE power(p1 -
            CASE
                WHEN outcome_idx = 1 THEN 1
                ELSE 0
            END::numeric, 2::numeric) + power(p2 -
            CASE
                WHEN outcome_idx = 2 THEN 1
                ELSE 0
            END::numeric, 2::numeric) + power(COALESCE(p3, 0::numeric) -
            CASE
                WHEN outcome_idx = 3 THEN 1
                ELSE 0
            END::numeric, 2::numeric)
        END AS brier_model,
        CASE
            WHEN ref1 IS NULL OR ref2 IS NULL OR n_classes = 3 AND ref3 IS NULL THEN NULL::numeric
            WHEN n_classes = 2 THEN power(ref1 -
            CASE
                WHEN outcome_idx = 1 THEN 1
                ELSE 0
            END::numeric, 2::numeric) + power(ref2 -
            CASE
                WHEN outcome_idx = 2 THEN 1
                ELSE 0
            END::numeric, 2::numeric)
            ELSE power(ref1 -
            CASE
                WHEN outcome_idx = 1 THEN 1
                ELSE 0
            END::numeric, 2::numeric) + power(ref2 -
            CASE
                WHEN outcome_idx = 2 THEN 1
                ELSE 0
            END::numeric, 2::numeric) + power(ref3 -
            CASE
                WHEN outcome_idx = 3 THEN 1
                ELSE 0
            END::numeric, 2::numeric)
        END AS brier_ref,
        CASE
            WHEN n_classes = 2 THEN 0.5
            ELSE 2.0 / 3.0
        END AS brier_naive,
    - ln(GREATEST(
        CASE outcome_idx
            WHEN 1 THEN p1
            WHEN 2 THEN p2
            ELSE p3
        END, 0.000001)) AS logloss_model,
        CASE
            WHEN ref1 IS NULL OR ref2 IS NULL OR n_classes = 3 AND ref3 IS NULL THEN NULL::numeric
            ELSE - ln(GREATEST(
            CASE outcome_idx
                WHEN 1 THEN ref1
                WHEN 2 THEN ref2
                ELSE ref3
            END, 0.000001))
        END AS logloss_ref,
    GREATEST(p1, p2, COALESCE(p3, '-1'::integer::numeric)) AS confidence,
        CASE
            WHEN p1 >= p2 AND (p3 IS NULL OR p1 >= p3) THEN outcome_idx = 1
            WHEN p2 >= p1 AND (p3 IS NULL OR p2 >= p3) THEN outcome_idx = 2
            ELSE outcome_idx = 3
        END AS leader_correct
   FROM v2.model_learning_observation o;
select v2.refresh_model_learning_gates();
commit;
