-- ============================================================================
-- iss033 ADVERSARIAL TEMPORAL REPLAY — READ-ONLY (CTE only, NO mutation)
-- Prueba §7: para 5 eventos reales de perfiles distintos (LaLiga, Grecia, UCL,
-- UEL, Belgica), computa features AS-OF (A), inyecta partidos SINTETICOS
-- posteriores a decision (goleadas), recomputa AS-OF (B), y computa el agregado
-- MOVIL contaminado. Invariante: A == B (as-of inmune) y MOVIL != A.
-- Ejecutado 2026-09-09 contra prod (read-only). Evidencia en
-- shadow-patches/reports/ISS033_hostile_audit_2026-09-09.md
-- Version deployable (usando v2.fn_soccer_features_asof) en iss033_temporal_replay_test.sql
-- ============================================================================
with picks as (
  select * from (values
    ('LaLiga-140', 140), ('Grecia-197',197), ('UCL-2',2), ('UEL-3',3), ('Belgica-144',144)
  ) t(profile, liga_id)
),
ev as (
  select distinct on (p.liga_id) p.profile, h.liga_id, h.espn_event_id, h.home_espn_id, h.away_espn_id, h.fecha as decision
  from picks p
  join public.historico_partidos_espn h on h.liga_id=p.liga_id and h.home_score is not null
  where h.fecha < now() - interval '400 days'
  order by p.liga_id, h.fecha desc
),
syn as (
  select e.espn_event_id as key, x.* from ev e
  cross join lateral (values
    (e.home_espn_id, e.away_espn_id, e.decision + interval '30 days', 9, 0),
    (e.away_espn_id, e.home_espn_id, e.decision + interval '31 days', 0, 8),
    (e.home_espn_id, e.away_espn_id, e.decision + interval '32 days', 7, 1)
  ) x(home_id, away_id, f, hs, as_)
),
calc as (
  select e.profile, e.liga_id, e.decision,
    (select avg(home_score) from public.historico_partidos_espn z where z.home_espn_id=e.home_espn_id and z.liga_id=e.liga_id and z.home_score is not null and z.fecha<e.decision and z.fecha>=e.decision-interval '540 days') a_hgf,
    (select avg(gf) from (
        select home_score gf, fecha from public.historico_partidos_espn z where z.home_espn_id=e.home_espn_id and z.liga_id=e.liga_id and z.home_score is not null
        union all select hs, f from syn s where s.key=e.espn_event_id and s.home_id=e.home_espn_id
     ) u where u.fecha<e.decision and u.fecha>=e.decision-interval '540 days') b_hgf,
    (select avg(gf) from (
        select home_score gf from public.historico_partidos_espn z where z.home_espn_id=e.home_espn_id and z.liga_id=e.liga_id and z.home_score is not null
        union all select hs from syn s where s.key=e.espn_event_id and s.home_id=e.home_espn_id
     ) u) mov_hgf
  from ev e
)
select profile, liga_id, decision::date,
  round(a_hgf,4) a_home_gf, round(b_hgf,4) b_home_gf, round(mov_hgf,4) moving_home_gf,
  (a_hgf is not distinct from b_hgf) as asof_immune,
  (mov_hgf is distinct from a_hgf) as moving_contaminated
from calc order by liga_id;
