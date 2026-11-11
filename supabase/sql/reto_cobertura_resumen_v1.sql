-- Resumen de cobertura: próximos partidos por deporte + selecciones internacionales + ligas con momios.
-- Lo usa resumen-estado-email. SECURITY DEFINER, solo service_role. Solo lectura.
create or replace function reto_cobertura_resumen_v1()
returns jsonb language sql security definer set search_path=public as $$
  select jsonb_build_object(
    'futbol_club', (select count(*) from agenda_espn where deporte='soccer' and fecha>now()
                    and liga_nombre !~* 'nations|friendl|amistoso'),
    'nfl', (select count(*) from agenda_espn where deporte='football' and fecha>now()),
    'nba', (select count(*) from reto_nba_agenda_v1 where fecha>now()),
    'nhl', (select count(*) from reto_nhl_agenda_v1 where fecha>now()),
    'tenis', (select count(*) from tenis_agenda_v1 where fecha>now()),
    'internacional', (select coalesce(jsonb_agg(jsonb_build_object('liga',liga_nombre,'n',n) order by n desc),'[]'::jsonb)
                      from (select liga_nombre, count(*) n from agenda_espn
                            where (liga_nombre ~* 'nations|friendl|amistoso') and fecha>now()
                            group by 1) q),
    'ligas_momios', (select count(distinct sport_key) from reto_odds_multicasa_v1
                     where sport_key like 'soccer%' and captured_at > now()-interval '2 days')
  );
$$;
revoke all on function reto_cobertura_resumen_v1() from public, anon, authenticated;
grant execute on function reto_cobertura_resumen_v1() to service_role;
