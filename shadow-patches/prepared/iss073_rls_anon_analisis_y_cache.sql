-- iss073 · Tres tablas más invisibles para `anon`. Es la tercera vez que muerde
--          el mismo patrón en esta sesión.
--
-- CÓMO APARECIÓ: después de arreglar el timeout de los picks de fútbol (iss068),
-- hice la verificación final como `anon` de todas las superficies tocadas.
-- `picks_futbol_cache` devolvía 0 filas aunque yo acababa de llenarla con 29.
-- Sin error. Sin aviso. Cero filas.
--
-- EL PATRÓN, ya visto en iss057 (nfl_lesiones_semana y nfl_depth_chart):
--   create policy X on tabla for select TO authenticated using (true);
-- `anon` no está en la política, así que RLS le devuelve el conjunto vacío EN
-- SILENCIO. El front hace Promise.all, recibe {data: []} sin error, y pinta una
-- pantalla vacía o un análisis incompleto. Nadie ve un error en ningún lado.
--
-- Y en `historico_partidos_espn` el error fue MÍO: en iss064 le di
--   grant select on public.historico_partidos_espn to anon, authenticated;
-- pero GRANT y RLS son DOS PUERTAS DISTINTAS. Abrí una y dejé la otra cerrada,
-- así que el grant no servía de nada. Lección para la próxima: cuando una tabla
-- tiene RLS activo, un GRANT sin política es un no-op.
--
-- MEDIDO COMO anon, antes -> después:
--   historico_partidos_espn        0 -> 42,584
--   analisis_partidos              0 ->    565     <- la tabla del ANÁLISIS
--   picks_futbol_cache             0 ->     29
--
-- `analisis_partidos` importa especialmente: es la tabla del análisis de partidos,
-- justo lo que el owner reclamó que "sigue sin llegar".
--
-- BARRIDO COMPLETO Y LO QUE NO TOQUÉ, A PROPÓSITO
-- Busqué todas las políticas SELECT con `authenticated` y sin `anon`: son 68.
-- NO las abrí en bloque, y no se deben abrir. La mayoría son correctas porque
-- protegen datos DEL USUARIO: parlays, picks, usuarios, user_roles, notificaciones,
-- config_staking, ajustes_cuenta, canasta, diario_decision, limites_usuario,
-- semana_bankroll, push_subscriptions, reto_picks_mostrados, alertas_enviadas,
-- fantasy_roster_semanal. Abrir ésas sería un agujero de seguridad, no un arreglo.
-- Solo abrí las tres de arriba, que son datos públicos de partidos.
-- Criterio para picks_futbol_cache: es una copia literal de las filas de
-- v_picks_futbol_calc, y esa vista (sin security_invoker, con grant a anon) ya
-- exponía exactamente ese contenido. Abrir el caché no expone nada nuevo.
-- Tablas como nfl_jugadores ni siquiera tienen GRANT para anon: ahí anon recibe un
-- ERROR visible, no un vacío silencioso, así que el front no las lee como anon.
--
-- CÓMO SE DETECTA ESTO EN EL FUTURO (la consulta que lo encontró):
--   with pol as (
--     select c.relname tabla, p.polname,
--            (select array_agg(r.rolname) from pg_roles r where r.oid = any(p.polroles)) roles
--     from pg_policy p join pg_class c on c.oid=p.polrelid
--     join pg_namespace n on n.oid=c.relnamespace
--     where n.nspname='public' and p.polcmd in ('r','*'))
--   select * from pol where 'authenticated' = any(roles) and not ('anon' = any(roles));
-- Y siempre, SIEMPRE, verificar con `set local role anon` y no como admin.
-- Probar como admin es lo que escondió estos bugs durante semanas.

drop policy if exists pfc_lectura on public.picks_futbol_cache;
create policy pfc_lectura on public.picks_futbol_cache
  for select to anon, authenticated using (true);

drop policy if exists "Authenticated can read analisis" on public.analisis_partidos;
create policy analisis_partidos_lectura on public.analisis_partidos
  for select to anon, authenticated using (true);

drop policy if exists hpe_lectura on public.historico_partidos_espn;
create policy hpe_lectura on public.historico_partidos_espn
  for select to anon, authenticated using (true);
