-- ISS137b — Fast RETO Brain health invariants
-- The old aggregate publication-leak view can force legacy model recomputation.
-- Health must inspect publication surfaces directly and stay cheap/read-only.

create or replace view public.v_reto_brain_invariant_leaks_v1 as
with checks as (
  select 'NFL_LEGACY_PICKS'::text invariant_name,
    (select count(*) from public.nfl_predicciones where mejor_pick is not null or mejor_prob is not null)::bigint leak_count,
    'Legacy NFL recommendation fields must remain empty.'::text detail
  union all
  select 'NFL_TABLERO_UNAUTHORIZED',
    (select count(*) from public.nfl_tablero where reto_modelo is not null and not v2.fn_nfl_release_allowed(reto_modelo)
      and (reto_pick is not null or reto_pick_prob is not null or p_reto_local is not null or p_reto_visitante is not null or reto_spread_pick is not null or reto_total_pick is not null))::bigint,
    'NFL board may not expose P_RETO/picks for a model whose release gate is closed.'
  union all
  select 'MLB_PUBLISHED_FAVORITES',
    (select count(*) from public.v_favorito_mlb where favorito_pct is not null)::bigint,
    'MLB favorites must remain empty until a canonical MLB Moneyline model is release-authorized.'
  union all
  select 'SOCCER_LEGACY_APOSTABLE',
    (select count(*) from public.v_picks_futbol_calc where apostable)::bigint,
    'Legacy soccer premium/calculated surface may not independently authorize bets.'
  union all
  select 'SOCCER_PUBLICATION_INVARIANT_LEAKS',
    (select count(*) from public.v_soccer_publication_invariant_leaks)::bigint,
    'Soccer identity/distribution/temporal/selector authority leaks.'
  union all
  select 'LEARNING_TEMPORAL_LEAKS',
    (select count(*) from v2.model_learning_observation where promotion_eligible and not temporal_safe)::bigint,
    'Learning rows marked promotable despite temporal leakage.'
  union all
  select 'UNVERSIONED_PROMOTABLE_ROWS',
    (select count(*) from v2.model_learning_observation where promotion_eligible and (model_version is null or btrim(model_version)='' or model_version ilike '%unversioned%'))::bigint,
    'Promotable learning rows missing exact model identity.'
  union all
  select 'BRAIN_TIMELINE_TEMPORAL_LEAKS',
    (select count(*) from public.v_reto_brain_prediction_timeline_v1 where temporal_safe is distinct from true or snapshot_at>=kickoff)::bigint,
    'Canonical Brain timeline contains a non-pregame/unsafe prediction.'
  union all
  select 'MONEY_WITHOUT_RELEASE_AUTHORITY',
    (select count(*) from public.v_reto_brain_release_authority_v1 where money_authorized and (not scientific_ready or not product_release_authorized))::bigint,
    'Money authority may never exceed scientific + product release authority.'
  union all
  select 'BANNED_LEGACY_AUTOMUTATORS_ACTIVE',
    (select count(*) from cron.job where active and jobname in ('recalibrate-model-weights-monday','recalcular-competencia-modelo'))::bigint,
    'Legacy heuristics that mutate weights or replace model probability with market must stay off.'
)
select * from checks where leak_count<>0;

create or replace view public.v_reto_brain_health_v1 as
select
  now() checked_at,
  (select count(*) from public.v_reto_brain_release_authority_v1)::bigint authority_rows,
  (select count(*) from public.v_reto_brain_release_authority_v1 where scientific_ready)::bigint scientific_ready_rows,
  (select count(*) from public.v_reto_brain_release_authority_v1 where product_release_authorized)::bigint product_release_rows,
  (select count(*) from public.v_reto_brain_release_authority_v1 where money_authorized)::bigint money_authorized_rows,
  (select count(*) from public.v_reto_brain_prediction_timeline_v1)::bigint timeline_rows,
  (select count(*) from v2.model_learning_observation)::bigint graded_learning_rows,
  (select count(*) from public.v_reto_brain_invariant_leaks_v1)::bigint invariant_failures,
  case when not exists(select 1 from public.v_reto_brain_invariant_leaks_v1) then 'PASS' else 'FAIL' end::text status;
