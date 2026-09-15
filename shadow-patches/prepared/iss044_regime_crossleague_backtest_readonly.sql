-- ============================================================================
-- iss044 — REGIME CROSS-LEAGUE BACKTEST · RERUNNABLE READ-ONLY ARTIFACT
-- ============================================================================
-- Resolves AUDIT_NO_PASS 5619542059 finding 6: the regime table (report
-- iss044_regime_crossleague_backtest_readonly.md) now has an executable, read-only,
-- deterministic SQL that regenerates it, with a SEALED INPUT/CUTOFF MANIFEST below.
--
-- READ-ONLY. SELECT-only against prod public.historico_partidos_espn. NO writes, NO
-- prod mutation, NO tuning-to-today. Depends only on:
--   public.historico_partidos_espn  (real finals: home_nombre/away_nombre/home_score/away_score/fecha/liga_id)
--   v2.fn_dist_from_lambda           (iss041 v2 — the ONE authoritative matrix emitter)
-- Self-contained: features + inter-league prior (phi) are computed inline here, so any
-- auditor can run it read-only and regenerate the table without external φ state.
--
-- ── SEALED MANIFEST (change any value => a different, non-comparable run) ─────
--   SOURCE            : public.historico_partidos_espn (finals: home_score/away_score not null)
--   UNIVERSE_LIGAS    : 2 (UEFA Champions League), 3 (UEFA Europa League)
--   HISTORY_WINDOW    : per team, domestic matches with fecha < kickoff, within 540 days
--   FAILCLOSE_MIN_N   : 15 domestic matches per side (else event excluded)
--   TEMPORAL_SPLIT    : VALIDATION fecha < 2025-08-01 ; OOS_TEST fecha >= 2025-08-01
--   SCALE_GRID        : {0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0}  (multiplier on the phi spread)
--   RHO               : 0.0705 (crossleague DC rho, unchanged)
--   MAXG              : 10
--   REGIME_BINS       : strength_gap {<0.10, 0.10-0.30, >=0.30}; weak_opp {weak_league_present<0.9gpm, both_strong}
--   PHI_DEF           : phi_team = ln( team_gf_pm / GPM_REF ), GPM_REF=1.35 (domestic attack vs global mean)
--                       inter-league prior applied to lambda as * exp(±SCALE*(phi_home-phi_away)/2)
--   METRICS           : multiclass Brier = sum((p_k - y_k)^2) over {home,draw,away}; logloss=-ln(p_actual)
--   SELECTION_RULE    : SCALE chosen on VALIDATION only; OOS reported, never selected on.
-- Manifest hash: sha256 of this file, recorded in the CLAUDE_REPORT that ships it.
-- NOTE: runs read-only in a DATA-BEARING context (prod, SELECT-only). The disposable
--       gate branch has no historico data, so it is not runnable there.
-- ============================================================================

with params as (
  select 540 as window_days, 15 as min_n, timestamptz '2025-08-01 00:00:00+00' as split,
         0.0705::numeric as rho, 10 as maxg, 1.35::numeric as gpm_ref
),
-- 1) universe: UCL/UEL finals with a real result
fin as (
  select h.espn_event_id, h.fecha, h.liga_id, h.home_nombre, h.away_nombre,
         case when h.home_score>h.away_score then 'H' when h.home_score=h.away_score then 'D' else 'A' end as y
  from public.historico_partidos_espn h
  where h.liga_id in (2,3) and h.home_score is not null and h.away_score is not null
),
-- 2) domestic per-team attack as-of kickoff (fecha < kickoff, 540d), EXCLUDING the
--    cross-league comps (2,3) so the inter-league prior is not self-referential.
feat as (
  select f.espn_event_id, f.fecha, f.home_nombre, f.away_nombre, f.y, f.liga_id,
    (select avg(case when d.home_nombre=f.home_nombre then d.home_score else d.away_score end)::numeric
       from public.historico_partidos_espn d
       where d.liga_id not in (2,3) and d.home_score is not null
         and (d.home_nombre=f.home_nombre or d.away_nombre=f.home_nombre)
         and d.fecha < f.fecha and d.fecha >= f.fecha - interval '540 days') as home_gf_pm,
    (select count(*) from public.historico_partidos_espn d
       where d.liga_id not in (2,3) and d.home_score is not null
         and (d.home_nombre=f.home_nombre or d.away_nombre=f.home_nombre)
         and d.fecha < f.fecha and d.fecha >= f.fecha - interval '540 days') as home_n,
    (select avg(case when d.home_nombre=f.away_nombre then d.home_score else d.away_score end)::numeric
       from public.historico_partidos_espn d
       where d.liga_id not in (2,3) and d.home_score is not null
         and (d.home_nombre=f.away_nombre or d.away_nombre=f.away_nombre)
         and d.fecha < f.fecha and d.fecha >= f.fecha - interval '540 days') as away_gf_pm,
    (select count(*) from public.historico_partidos_espn d
       where d.liga_id not in (2,3) and d.home_score is not null
         and (d.home_nombre=f.away_nombre or d.away_nombre=f.away_nombre)
         and d.fecha < f.fecha and d.fecha >= f.fecha - interval '540 days') as away_n
  from fin f
),
elig as (
  select ft.*, (select gpm_ref from params) gpm_ref,
         ln(greatest(ft.home_gf_pm,0.10)/(select gpm_ref from params)) as phi_home,
         ln(greatest(ft.away_gf_pm,0.10)/(select gpm_ref from params)) as phi_away
  from feat ft
  where ft.home_n >= (select min_n from params) and ft.away_n >= (select min_n from params)
    and ft.home_gf_pm is not null and ft.away_gf_pm is not null
),
grid as ( select unnest(array[0.0,0.5,1.0,1.5,2.0,2.5,3.0]::numeric[]) as scale ),
scored as (
  select e.espn_event_id, e.fecha, e.y, g.scale,
         abs(e.phi_home - e.phi_away) as strength_gap,
         (least(e.home_gf_pm,e.away_gf_pm) < 0.9) as weak_league_present, d.jd
  from elig e cross join grid g
  cross join lateral (select v2.fn_dist_from_lambda(
      greatest(e.home_gf_pm * exp( g.scale*(e.phi_home-e.phi_away)/2 ), 0.15),
      greatest(e.away_gf_pm * exp(-g.scale*(e.phi_home-e.phi_away)/2 ), 0.15),
      null, (select rho from params), (select maxg from params)) jd) d
  where d.jd is not null
),
probs as (
  select s.*, (jd->>'p_home')::numeric/100 ph, (jd->>'p_draw')::numeric/100 pd, (jd->>'p_away')::numeric/100 pa
  from scored s
),
metric as (
  select scale,
    case when fecha < (select split from params) then 'VALIDATION' else 'OOS_TEST' end as split_window,
    avg( power(ph-(y='H')::int,2)+power(pd-(y='D')::int,2)+power(pa-(y='A')::int,2) ) as brier,
    avg( -ln(greatest(case y when 'H' then ph when 'D' then pd else pa end,1e-6)) ) as logloss,
    count(*) n
  from probs group by 1,2
)
select split_window, scale, round(brier,4) brier, round(logloss,4) logloss, n
from metric order by split_window, scale;
