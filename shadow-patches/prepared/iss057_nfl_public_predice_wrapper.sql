-- ISS057 — NFL canonical P_RETO public read contract
-- Root cause: public.nfl_dossier() is SECURITY INVOKER and its direct call to
-- v2.fn_nfl_reto_predice() fails for anon (no USAGE/SELECT on v2), then an
-- EXCEPTION WHEN OTHERS silently drops reto_predice.
--
-- Security design:
--   * DO NOT grant anon SELECT on v2.nfl_decision_snapshot.
--   * DO NOT grant anon broad USAGE on v2.
--   * Expose only the already-curated JSON returned by fn_nfl_reto_predice.
--   * Do not catch unexpected errors here: an authorization/runtime regression
--     must be visible rather than silently degrading to "no model".

begin;

create or replace function public.nfl_reto_predice(p_event text)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public, v2
as $$
  select v2.fn_nfl_reto_predice(p_event);
$$;

revoke all on function public.nfl_reto_predice(text) from public;
grant execute on function public.nfl_reto_predice(text) to anon, authenticated, service_role;

comment on function public.nfl_reto_predice(text) is
  'Narrow public NFL P_RETO contract. Returns only curated v2.fn_nfl_reto_predice JSON; does not expose v2 snapshot tables.';

commit;

-- REQUIRED VALIDATION (disposable branch / transaction fixture):
-- 1) privileged and anon outputs must be identical for a READY event.
--    SET LOCAL ROLE anon;
--    SELECT public.nfl_reto_predice('401872657');
--    Expected canonical fields: disponible=true, model_version=nfl-2026.09.2,
--    ganador local Rams p_local=65.2, fuente_probabilidad=nfl_points_lattice_v2.
-- 2) Historical event with no pregame snapshot returns NULL:
--    SELECT public.nfl_reto_predice('401872656');
-- 3) Unknown event returns NULL.
-- 4) has_table_privilege('anon','v2.nfl_decision_snapshot','SELECT') remains FALSE.
-- 5) PostgREST anon RPC works after NOTIFY pgrst, 'reload schema'.
