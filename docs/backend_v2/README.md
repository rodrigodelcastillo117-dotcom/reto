# RETO 13M V2 — Backend (soccer) versioned snapshot

This folder versions, in Git, the V2 soccer backend objects that live in Supabase
project `wpiztubmmmzclhlprgpd` (prod). It exists so the backend is **reproducible
and auditable**, not only "live in prod".

## Files
- `v2_objects_snapshot.sql` — core engine: `v2.fn_dist_from_lambda`, `v2.fn_score_dist`,
  `v2.build_soccer_prediction_v2` + `model_registry` approved-list + governance note.
- `v2_read_contracts.sql` — public read contracts: `v_futpro_v2`, `v_reto13m_daily`
  (full DDL) and pointer for `v_analisis_v2`.

## Objects in prod (manifest)
Tables (schema `v2`): `competition_catalog`, `model_registry`, `liga_alias`,
`team_logo`, `soccer_prediction_v2` (immutable versioned snapshots).
Functions (schema `v2`): `fn_dist_from_lambda`, `fn_score_dist`,
`build_soccer_prediction_v2`, `fn_market_anchored_dist` (kept, NOT used for P_RETO).
Views (schema `public`): `v_futpro_v2`, `v_analisis_v2`, `v_reto13m_daily`.
Cron: `v2_build_soccer_prediction` (jobid 419, `15 */3 * * *`, additive).
Destructive `v2_rebuild_soccer_snapshot` (jobid 418) is UNSCHEDULED.

## Governance (single source of truth)
`v2.model_registry.approved` decides which competitions publish P_RETO. As of
2026-09-09 the approved set is 11 domestic leagues (liga_id): 78 Bundesliga,
88 Eredivisie, 140 La Liga, 262 Liga MX, 94 Liga Portugal, 61 Ligue 1, 253 MLS,
39 Premier League, 307 Saudi Pro League, 135 Serie A, 203 Süper Lig.
`v2.competition_catalog.model_supported` MUST mirror this (enforced 2026-09-09;
`provider_competition_id` now carries the ESPN liga_id for the approved rows).
A competition can be VISIBLE without a model (`enabled=true`), but must NOT be
`model_supported=true` unless registry approves it. Champions/Europa/Conference/
CONCACAF/Libertadores/Sudamericana/Leagues Cup/etc. → P_RETO NULL (fail-closed).

## Re-dump the live definitions (to refresh these files)
```sql
-- functions
select pg_get_functiondef(p.oid)||';'
from pg_proc p join pg_namespace n on n.oid=p.pronamespace
where n.nspname='v2' and p.proname in ('fn_dist_from_lambda','fn_score_dist','build_soccer_prediction_v2');
-- views
select 'CREATE OR REPLACE VIEW public.'||c.relname||' AS '||pg_get_viewdef(c.oid,true)||';'
from pg_class c join pg_namespace n on n.oid=c.relnamespace
where n.nspname='public' and c.relname in ('v_futpro_v2','v_analisis_v2','v_reto13m_daily');
```

## Migrations applied this closure (slice 29A)
- `v_futpro_v2_drop_double_chance_from_mejor_pick`
- `v_reto13m_daily_restrict_markets_ml_btts_over25`
- `v_analisis_v2_add_xg_h2h_tendencias`
- `v_analisis_v2_fix_dedup_fuerza_one_row_per_event`  (P0: 639→254 rows, 1/event)
- `competition_catalog_align_model_supported_to_registry`  (governance)
