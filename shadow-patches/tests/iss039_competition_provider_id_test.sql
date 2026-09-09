-- ============================================================================
-- iss039 TEST — §20 competition identity por provider-id (no por nombre)
-- Requiere iss039 (competition_provider_map + fn_resolve_competition +
--   fn_competition_map_integrity). Branch-only. Siembra y limpia sus fixtures.
-- Cubre: resolución por id numérico; fail-close si id no mapeado; variante de grafía
--   del MISMO id sigue resolviendo por id; la PK impide colisión de id; label-collision
--   (mismo nombre, ids distintos) se detecta como diagnóstico, no como clave.
-- ============================================================================
delete from v2.competition_provider_map where provider='espn_test';
do $$
declare r record; ig record; got_error boolean;
begin
  insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,competition_label,mapping_version)
  values ('espn_test',197,197,'Grecia SL','tv1'), ('espn_test',39,39,'LaLiga','tv1');
  select * into r from v2.fn_resolve_competition('espn_test',197,'tv1');
  if r.competition_id is distinct from 197 then raise exception 'FAIL resolve 197'; end if;
  if exists(select 1 from v2.fn_resolve_competition('espn_test',999,'tv1')) then raise exception 'FAIL fail-close id no mapeado'; end if;
  select * into ig from v2.fn_competition_map_integrity('tv1');
  if ig.id_collisions<>0 or ig.label_collisions<>0 then raise exception 'FAIL integridad inicial'; end if;
  -- variante de grafía del MISMO id: sigue resolviendo por id
  update v2.competition_provider_map set competition_label='Grecia Super League'
    where provider='espn_test' and provider_competition_id=197 and mapping_version='tv1';
  select * into r from v2.fn_resolve_competition('espn_test',197,'tv1');
  if r.competition_id is distinct from 197 then raise exception 'FAIL variante de nombre rompió mapeo por id'; end if;
  -- la PK impide estructuralmente una colisión de id
  got_error := false;
  begin
    insert into v2.competition_provider_map(provider,provider_competition_id,competition_id,mapping_version)
    values ('espn_test',197,888,'tv1');
  exception when unique_violation then got_error := true; end;
  if not got_error then raise exception 'FAIL: la PK debió impedir colisión de id'; end if;
  -- label-collision (mismo label, ids distintos) => diagnóstico, no clave
  update v2.competition_provider_map set competition_label='Grecia Super League'
    where provider='espn_test' and provider_competition_id=39 and mapping_version='tv1';
  select * into ig from v2.fn_competition_map_integrity('tv1');
  if ig.id_collisions<>0 then raise exception 'FAIL id_collision espuria'; end if;
  if ig.label_collisions<1 then raise exception 'FAIL label collision no detectada'; end if;
  delete from v2.competition_provider_map where provider='espn_test';
  raise notice 'PASS iss039 §20';
end $$;
