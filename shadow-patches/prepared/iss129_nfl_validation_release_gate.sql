-- ============================================================================
-- ISS129 — NFL VALIDATION RELEASE GATE · FAIL CLOSED · STAGED
-- ============================================================================
-- NO PROD MUTATION in this commit. Apply/test on disposable first.
--
-- Problem proven by audit:
--   * nfl-2026.09.2 has its own model/distribution and temporal snapshots.
--   * production config says publish_authorized=true while calibration_status says
--     BACKTESTED_2025_NO_EDGE_VS_MARKET.
--   * the 2025 diagnostic is not a clean OOS calibration proof because parameters
--     and the empirical points lattice were estimated from 2025 while 2025 is also
--     the evaluated season.
--   * 2026 currently has only two completed regular-season games: insufficient to
--     establish calibration.
--
-- Governance decision:
--   Model computation may remain available for diagnostics, but publication is
--   authorized ONLY by this separate, immutable validation gate. Missing row = DENY.
--   Market/no-vig never authorizes or calibrates P_RETO.
-- ============================================================================

create schema if not exists v2;

create table if not exists v2.nfl_model_validation_gate (
  model_version text primary key,
  evaluation_version text not null,
  validation_status text not null,
  n_oos_events int not null default 0 check (n_oos_events >= 0),
  brier_model numeric,
  brier_reference numeric,
  max_abs_calibration_gap_pp numeric,
  publish_authorized boolean not null default false,
  evidence jsonb not null,
  sealed_at timestamptz not null default now(),
  constraint nfl_validation_gate_status_check check (
    validation_status in (
      'OOS_VALIDATED',
      'OOS_VALIDATION_PENDING',
      'OOS_VALIDATION_FAILED',
      'FAIL_CLOSED_OOS_NOT_PROVEN'
    )
  ),
  constraint nfl_validation_publish_requires_oos check (
    publish_authorized = false or validation_status = 'OOS_VALIDATED'
  )
);

create or replace function v2.fn_nfl_validation_gate_immutable()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'NFL_VALIDATION_GATE_IMMUTABLE: DELETE prohibited; supersede with a new model/evaluation version';
  end if;
  if to_jsonb(new) is distinct from to_jsonb(old) then
    raise exception 'NFL_VALIDATION_GATE_IMMUTABLE: % is sealed; create a new model/evaluation version', old.model_version;
  end if;
  return new;
end $$;

drop trigger if exists trg_nfl_validation_gate_immutable on v2.nfl_model_validation_gate;
create trigger trg_nfl_validation_gate_immutable
before update or delete on v2.nfl_model_validation_gate
for each row execute function v2.fn_nfl_validation_gate_immutable();

-- Exact current NFL authority. Fail closed until a genuinely independent OOS
-- outcome validation exists. Market comparison is recorded only as diagnostic context.
insert into v2.nfl_model_validation_gate (
  model_version, evaluation_version, validation_status, n_oos_events,
  brier_model, brier_reference, max_abs_calibration_gap_pp,
  publish_authorized, evidence
) values (
  'nfl-2026.09.2',
  'nfl_oos_gate_v1',
  'FAIL_CLOSED_OOS_NOT_PROVEN',
  0,
  null, null, null,
  false,
  jsonb_build_object(
    'reason','2025 diagnostic reuses 2025-estimated global parameters/points lattice; not independent OOS calibration proof',
    'completed_2026_regular_games_at_audit',2,
    'market_role','diagnostic/economic context only; never P_RETO target or fallback',
    'known_diagnostic','40-50% bucket showed material calibration error in prior walk-forward diagnostic',
    'required_to_authorize','new model/evaluation version with temporally clean OOS outcome validation and stable calibration'
  )
) on conflict (model_version) do nothing;

create or replace function v2.fn_nfl_release_allowed(p_model_version text)
returns boolean language sql stable as $$
  select coalesce((
    select g.publish_authorized and g.validation_status='OOS_VALIDATED'
    from v2.nfl_model_validation_gate g
    where g.model_version=p_model_version
  ), false);
$$;

-- Canonical candidate surface: model-only ranking, but only after the independent
-- validation authority permits publication. Missing gate row => zero candidates.
create or replace view v2.v_nfl_daily_candidates as
with legs as (
  select s.espn_event_id, s.decision_time, s.model_version,
         s.temporada, s.semana, s.kickoff, s.home_team, s.away_team,
         s.quality_status, s.calibration_status, s.coverage, s.uncertainty,
         c.market, c.side, c.line, c.p_reto, c.push
  from v2.nfl_decision_snapshot s
  join v2.nfl_model_validation_gate g
    on g.model_version=s.model_version
   and g.publish_authorized=true
   and g.validation_status='OOS_VALIDATED'
  cross join lateral (values
    ('ML'::text,     s.home_team, null::numeric,     s.p_home_ml,    null::numeric),
    ('ML',           s.away_team, null::numeric,     s.p_away_ml,    null::numeric),
    ('SPREAD',       s.home_team, s.dk_spread_home,  s.p_home_cover, s.p_spread_push),
    ('SPREAD',       s.away_team, -s.dk_spread_home, s.p_away_cover, s.p_spread_push),
    ('TOTAL',        'OVER',      s.dk_total,        s.p_over,       s.p_total_push),
    ('TOTAL',        'UNDER',     s.dk_total,        s.p_under,      s.p_total_push)
  ) c(market, side, line, p_reto, push)
  where s.model_status='READY' and c.p_reto is not null
)
select * from legs;

-- Public/read surface remains useful for fixtures and diagnostics, but probabilities
-- are NULL unless the validation gate authorizes this exact model_version.
create or replace view public.nfl_reto_modelo as
select distinct on (s.espn_event_id)
  s.espn_event_id,
  s.home_team,
  s.away_team,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_home_ml end as p_home_ml,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_away_ml end as p_away_ml,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_tie_regulation end as p_tie_regulation,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_home_cover end as p_home_cover,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_away_cover end as p_away_cover,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_spread_push end as p_spread_push,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_over end as p_over,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_under end as p_under,
  case when v2.fn_nfl_release_allowed(s.model_version) then s.p_total_push end as p_total_push,
  s.dk_spread_home,
  s.dk_total,
  s.exp_home,
  s.exp_away,
  s.exp_total,
  s.exp_margin,
  s.uncertainty,
  s.coverage,
  s.model_version,
  case when v2.fn_nfl_release_allowed(s.model_version)
       then s.model_status else 'VALIDATION_BLOCKED' end as model_status,
  coalesce(g.validation_status, 'FAIL_CLOSED_OOS_NOT_PROVEN') as calibration_status,
  case when v2.fn_nfl_release_allowed(s.model_version)
       then s.quality_status else 'SUPPRESSED' end as quality_status,
  case when v2.fn_nfl_release_allowed(s.model_version)
       then s.suppression_reason
       else 'P_RETO bloqueado: validacion OOS independiente no demostrada' end as suppression_reason,
  s.prob_source,
  s.decision_time,
  s.kickoff
from v2.nfl_decision_snapshot s
left join v2.nfl_model_validation_gate g on g.model_version=s.model_version
order by s.espn_event_id, s.decision_time desc, s.built_at desc;

-- Hard audit views. Both must return zero rows at PASS.
create or replace view v2.v_nfl_unauthorized_candidate_leaks as
select c.*
from v2.v_nfl_daily_candidates c
where not v2.fn_nfl_release_allowed(c.model_version);

create or replace view v2.v_nfl_public_probability_leaks as
select p.*
from public.nfl_reto_modelo p
where not v2.fn_nfl_release_allowed(p.model_version)
  and (p.p_home_ml is not null or p.p_away_ml is not null
       or p.p_home_cover is not null or p.p_away_cover is not null
       or p.p_over is not null or p.p_under is not null);

-- Optional compatibility hardening for existing config: the config's historical
-- publish_authorized flag is NOT sufficient authority. All release decisions go through
-- fn_nfl_release_allowed(), so sealed legacy rows need not be mutated.
comment on table v2.nfl_model_validation_gate is
  'Sole NFL publication authorization gate. Missing row or non-OOS_VALIDATED status fails closed. Market/no-vig cannot authorize P_RETO.';
