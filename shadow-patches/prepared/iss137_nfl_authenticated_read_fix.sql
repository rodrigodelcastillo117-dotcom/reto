-- ISS137 — NFL authenticated read fix
-- 2026-09-13
-- Root cause: public.nfl_tablero_semana calls v2.fn_nfl_release_allowed(text).
-- That SQL function ran with caller privileges, so authenticated users hit
-- `permission denied for schema v2` even though the public view itself was readable.
-- Keep release semantics unchanged; only execute the gate under its owner.

create or replace function v2.fn_nfl_release_allowed(p_model_version text)
returns boolean
language sql
stable
security definer
set search_path = 'v2', 'public', 'pg_temp'
as $$
  select coalesce((
    select g.publish_authorized and g.validation_status='OOS_VALIDATED'
    from v2.nfl_model_validation_gate g
    where g.model_version=p_model_version
  ), false);
$$;

comment on function v2.fn_nfl_release_allowed(text) is
  'Release gate only. SECURITY DEFINER prevents public/authenticated readers of public NFL views from needing direct v2 schema privileges; release semantics unchanged.';
