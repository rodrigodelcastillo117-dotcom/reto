-- ============================================================================
-- gen_soccer_realpath_seed.sql — REPRODUCE the real-path branch seed from PROD
-- ============================================================================
-- READ-ONLY against production (wpiztubmmmzclhlprgpd). Run each SELECT and apply the
-- emitted INSERT text to the disposable branch. This is the exact provenance of the data
-- used in the executed SOCCER real-path gate, so the auditor can rebuild it byte-for-byte
-- instead of trusting a committed snapshot.
--
-- DECISION EPOCH: 2026-09-10 12:00:00+00 (pre-kickoff for all six owner fixtures, and
-- after their 11:49:02Z pregame line capture).
-- ============================================================================

-- 1) AGENDA universe at the epoch (237 rows on 2026-09-10). The builder reads exactly these
--    columns; provider endpoint/estado metadata is not read by the pipeline.
select count(*) n, string_agg(format('(%L,%s,%L,%L,%L,%L,%L,%L)',
  espn_event_id, liga_id, liga_nombre, fecha, home_espn_id, away_espn_id, home_nombre, away_nombre),
  ',' order by espn_event_id) insert_values
from (select distinct on (espn_event_id) espn_event_id, liga_id, liga_nombre, fecha,
        home_espn_id, away_espn_id, home_nombre, away_nombre
      from public.agenda_espn
      where deporte='soccer' and fecha > '2026-09-10 12:00:00+00'::timestamptz
      order by espn_event_id, fecha) z;

-- 2) REAL pregame lines: latest confiable row with a total line at or before the decision
--    (154 rows on 2026-09-10). Never a fabricated or nearest line.
with ev as (select distinct espn_event_id from public.agenda_espn
            where deporte='soccer' and fecha > '2026-09-10 12:00:00+00'::timestamptz),
l as (select distinct on (m.espn_event_id) m.espn_event_id, m.home_ml, m.away_ml, m.draw_ml,
        m.over_odds, m.under_odds, m.over_line, m.snapshot_at, m.bookmaker, m.overround
      from public.v_momios_confiables m join ev on ev.espn_event_id=m.espn_event_id
      where m.confiable is true and m.over_line is not null
        and m.snapshot_at <= '2026-09-10 12:00:00+00'::timestamptz
      order by m.espn_event_id, m.snapshot_at desc)
select count(*) n, string_agg(format('(%L,%s,%s,%s,%s,%s,%s,%L,%L,%s)',
  espn_event_id, coalesce(home_ml::text,'null'), coalesce(away_ml::text,'null'), coalesce(draw_ml::text,'null'),
  coalesce(over_odds::text,'null'), coalesce(under_odds::text,'null'), over_line,
  snapshot_at, bookmaker, coalesce(overround::text,'null')), ',' order by espn_event_id) insert_values
from l;

-- 3) DOMESTIC-FORM closure for the twelve owner-fixture teams (429 rows on 2026-09-10).
--    This is the crossleague model's feature input. The excluded liga_id list is the FROZEN
--    set from v2.fn_crossleague_features (feature_version crossleague_domestic_form_asof_v1);
--    it is part of the validated feature definition and must not be "tidied".
--    MEASURED: 493 Shakhtar, 494 Slavia Prague and 21922 Sabah FK return ZERO rows — prod
--    holds no domestic FINAL match for them in the window. That is the real, auditable reason
--    their fixtures fail-close, and the seed must not invent rows to paper over it.
with t(tid) as (values ('148'),('493'),('494'),('175'),('2572'),('11420'),
                       ('360'),('21922'),('132'),('2980'),('436'),('104'))
select count(*) n, string_agg(format('(%L,%s,%L,%L,%L,%s,%s,%L)',
  espn_event_id, liga_id, fecha, home_espn_id, away_espn_id, home_score, away_score, cargado_at),
  ',' order by espn_event_id) insert_values
from (select distinct d.espn_event_id, d.liga_id, d.fecha, d.home_espn_id, d.away_espn_id,
             d.home_score, d.away_score, d.cargado_at
      from public.historico_partidos_espn d
      where (d.home_espn_id in (select tid from t) or d.away_espn_id in (select tid from t))
        and d.liga_id not in (2,3,848,13,11,15,16,17,20,45,48,66,81,137,143,180,181,667)
        and d.liga_id is not null and d.home_score is not null
        and d.fecha <  '2026-09-10 12:00:00+00'::timestamptz
        and d.fecha >= '2026-09-10 12:00:00+00'::timestamptz - interval '540 days') z;

-- 4) competition_catalog (29 real prod soccer rows). Committed verbatim in
--    seed_soccer_crossleague_data.sql; regenerate with:
select count(*) n, string_agg(format('(%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%L,%s,%L)',
  competition_id,sport,provider,provider_competition_id,canonical_name,country,region,group_name,
  enabled,model_supported,show_in_futpro,show_in_favorites,show_in_reto13m,
  coalesce(display_order::text,'null'),season_mode), E',\n' order by competition_id) insert_values
from v2.competition_catalog where sport='soccer';

-- 5) PROVENANCE of the sealed phi cutoff (no prod read needed):
--    lab/champions_crossleague_v1/validation_v2.json -> leakage.max_fecha = 2026-09-08,
--    i.e. the latest cross-league kickoff used to identify phi. The snapshot is therefore
--    sealed at 2026-09-09 00:00:00+00 (data used: kickoff < cutoff), strictly before the
--    2026-09-10 12:00Z decision epoch. Seal it on the branch with:
--      select v2.fn_seal_liga_fuerza_snapshot('crossleague_v1', timestamptz '2026-09-09 00:00:00+00', 10.0, 39);
