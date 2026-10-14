-- Evidencia reproducible para mlb_money_auditor_decision_package.md
-- Solo LECTURA. No modifica nada. prod wpiztubmmmzclhlprgpd.

-- ========== A) FORWARD PURO (muestra del gate, con fuente de kickoff corregida) ==========
with cfg as (select candidate_model_version from v2.mlb_canonical_model_config_v1
             where public_model_version='mlb_canonical_v1'),
graded as (
  select f.p_raw_home, f.resultado,
         ((f.p_raw_home-f.resultado::numeric)^2)-0.25 as brier_delta
  from lab_mlb_forward f cross join cfg
  left join historico_partidos_espn h on h.espn_event_id=f.espn_event_id
  left join agenda_espn a on a.espn_event_id=f.espn_event_id and a.deporte='baseball'
  where f.model_version=cfg.candidate_model_version
    and f.eligibility_state='FORWARD_VALIDATION_PENDING'
    and f.resultado=any(array[0,1])
    and f.decision_time>'2026-08-30 00:00:00+00'
    and coalesce(h.fecha,a.fecha) is not null
    and f.decision_time<coalesce(h.fecha,a.fecha)
    and f.available_at_decision='AVAILABLE_AT_DECISION'
    and f.cache_timestamp is not null and f.cache_timestamp<=f.decision_time
    and f.p_raw_home>0 and f.p_raw_home<1
    and coalesce(f.notes,'') !~~* '%SYNTHETIC%'
),
bk as (select floor(p_raw_home*10)/10 bucket, count(*) n, avg(p_raw_home) pa, avg(resultado) ya from graded group by 1)
select 'FORWARD' pool, count(*) n,
  round(avg((p_raw_home-resultado)^2)::numeric,5) brier,
  round(avg(-(resultado*ln(greatest(p_raw_home,1e-6))+(1-resultado)*ln(greatest(1-p_raw_home,1e-6))))::numeric,5) logloss,
  round((avg(brier_delta)+1.96*stddev_samp(brier_delta)/sqrt(count(*)))::numeric,5) brier_delta_up95,
  (select count(*) from bk where n>=20) supported_buckets,
  round((select max(abs(pa-ya))*100 from bk where n>=20)::numeric,1) max_gap_pp
from graded;

-- Buckets forward con significancia (Wald z)
with cfg as (select candidate_model_version from v2.mlb_canonical_model_config_v1 where public_model_version='mlb_canonical_v1'),
graded as (
  select f.p_raw_home, f.resultado from lab_mlb_forward f cross join cfg
  left join historico_partidos_espn h on h.espn_event_id=f.espn_event_id
  left join agenda_espn a on a.espn_event_id=f.espn_event_id and a.deporte='baseball'
  where f.model_version=cfg.candidate_model_version and f.eligibility_state='FORWARD_VALIDATION_PENDING'
    and f.resultado=any(array[0,1]) and f.decision_time>'2026-08-30 00:00:00+00'
    and coalesce(h.fecha,a.fecha) is not null and f.decision_time<coalesce(h.fecha,a.fecha)
    and f.available_at_decision='AVAILABLE_AT_DECISION' and f.cache_timestamp is not null
    and f.cache_timestamp<=f.decision_time and f.p_raw_home>0 and f.p_raw_home<1
    and coalesce(f.notes,'') !~~* '%SYNTHETIC%')
select floor(p_raw_home*10)/10 bucket, count(*) n, round(avg(p_raw_home)::numeric,3) model_p,
  round(avg(resultado)::numeric,3) actual, round((abs(avg(p_raw_home)-avg(resultado))*100)::numeric,1) gap_pp,
  round((abs(avg(p_raw_home)-avg(resultado))/nullif(sqrt(avg(resultado)*(1-avg(resultado))/count(*)),0))::numeric,2) z
from graded group by 1 order by 1;

-- ========== B) WALK-FORWARD BACKTEST (bt_mlb_ml, 1056 juegos, may-ago 2026) ==========
-- OJO: prob_cruda esta en PORCENTAJE (0-100).
with b as (select prob_cruda/100.0 p, gano_local y from bt_mlb_ml
           where prob_cruda>0 and prob_cruda<100 and gano_local in (0,1)),
bk as (select floor(p*10)/10 bucket, count(*) n, avg(p) pa, avg(y) ya from b group by 1)
select 'BACKTEST_WALKFWD' pool, count(*) n,
  round(avg((p-y)^2)::numeric,5) brier,
  round(avg(-(y*ln(greatest(p,1e-6))+(1-y)*ln(greatest(1-p,1e-6))))::numeric,5) logloss,
  round((avg((p-y)^2-0.25)+1.96*stddev_samp((p-y)^2-0.25)/sqrt(count(*)))::numeric,5) brier_delta_up95,
  (select count(*) from bk where n>=20) supported_buckets,
  round((select max(abs(pa-ya))*100 from bk where n>=20)::numeric,1) max_gap_pp
from b;

-- Buckets backtest con significancia
with b as (select prob_cruda/100.0 p, gano_local y from bt_mlb_ml where prob_cruda>0 and prob_cruda<100 and gano_local in (0,1))
select floor(p*10)/10 bucket, count(*) n, round(avg(p)::numeric,3) model_p, round(avg(y)::numeric,3) actual,
  round((abs(avg(p)-avg(y))*100)::numeric,1) gap_pp,
  round((abs(avg(p)-avg(y))/nullif(sqrt(avg(y)*(1-avg(y))/count(*)),0))::numeric,2) z
from b group by 1 order by 1;
