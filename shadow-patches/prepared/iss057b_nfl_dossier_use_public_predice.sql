-- ISS057b — Make public.nfl_dossier honor its P_RETO contract for anon clients.
-- Requires ISS057 public.nfl_reto_predice(text).
-- Root cause: nfl_dossier is SECURITY INVOKER; direct reference to v2 failed
-- for anon and EXCEPTION WHEN OTHERS silently dropped reto_predice.
-- This patch changes ONLY that call site to the narrow SECURITY DEFINER wrapper.

begin;

do $$
declare
  ddl text;
  old_call text := 'v2.fn_nfl_reto_predice(p_event)';
  new_call text := 'public.nfl_reto_predice(p_event)';
begin
  select pg_get_functiondef('public.nfl_dossier(text)'::regprocedure) into ddl;
  if position(old_call in ddl)=0 then
    raise exception 'expected direct v2 call not found in public.nfl_dossier(text)';
  end if;
  ddl := replace(ddl, old_call, new_call);
  execute ddl;
end $$;

commit;

-- Required validation:
-- SET LOCAL ROLE anon;
-- SELECT public.nfl_dossier('401872657')->'reto_predice'; -- disponible=true, LAR 65.2
-- SELECT public.nfl_dossier('401872656')->'reto_predice'; -- NULL historical no-snapshot
-- RESET ROLE;
