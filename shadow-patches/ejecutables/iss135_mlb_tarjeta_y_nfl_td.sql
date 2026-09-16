-- =====================================================================
-- ISS135 -- TARJETA DE MLB (ML, TOTAL REAL, NRFI/YRFI, F5) + CONTEXTO DE TD EN NFL
--
-- El dueno pidio cerrar la app: cada partido con analisis, cada linea
-- correcta, y en NFL "un prop de quien mete TD y porque".
--
-- ============ CORRECCION IMPORTANTE QUE ME DEBO ============
--
-- En ISS131 le dije al dueno que no habia yardas ni touchdowns porque
-- nfl_equipo_totales, nfl_defense_logs y nfl_depth_chart estaban vacias.
-- ESTABA MAL. Lo lei de pg_stat_user_tables, que da ESTIMACIONES y estaba
-- stale. Conteos reales:
--     nfl_depth_chart          247      nfl_equipo_totales     32
--     nfl_defense_vs_position  256      nfl_kicker_logs       536
--     nfl_lesiones_semana     2043      nfl_defense_logs      544
-- Es la SEGUNDA vez en esta sesion que esa vista me miente (la primera fue
-- nfl_fpi, que decia 0 y tenia 32). Regla para adelante: para decidir si
-- una tabla esta vacia, count(*), nunca n_live_tup.
--
-- ============ MLB: mv_tarjeta_mlb_v1 ============
--
-- Cuatro mercados, todos del cerebro canonico mlb_one_brain_v2:
--   1. Moneyline, etiquetado PREDICCION_NO_VALIDADA con la autoridad pegada
--      (ISS128: product_release_authorized=false, n_oos=14).
--   2. Total de carreras EN LA LINEA REAL, con PUSH.
--   3. NRFI / YRFI.
--   4. F5 con empate.
--
-- EL PUSH NO ES DECORATIVO EN MLB. A diferencia de futbol, aqui las lineas
-- enteras existen y son comunes. Medido sobre los juegos con linea:
--     linea 7   -> push 12.50%
--     linea 8   -> push 13.18%
--     linea 9   -> push 13.07%
--     lineas .5 -> push 0.00%
-- Un 13% de probabilidad de empate exacto no se puede ignorar: si la tarjeta
-- muestra solo over/under en una linea entera, no suma 100 y el pick se
-- califica mal. G31.2 y G31.3 lo vigilan en ambas direcciones.
--
-- ES MATERIALIZADA, no vista: llamar al cerebro por cada uno de los 103
-- juegos tarda mas de 60s. Se refresca cada 15 min por cron.
--
-- COBERTURA MEDIDA (103 juegos):
--     40 con analisis completo (ML, NRFI/YRFI, F5, carreras esperadas)
--     15 con linea de carreras
--     63 SIN analisis
-- Los 63 son juegos a 78+ horas. MLB no anuncia abridores con 3 dias de
-- anticipacion y el cerebro falla cerrado con DATA_UNAVAILABLE. Eso es
-- calendario, no bug: esos juegos entran solos conforme se acercan.
-- Los 88 sin linea son los mismos mas los que la casa aun no publica.
--
-- ============ NFL: nfl_td_contexto ============
--
-- Cruza tres cosas reales:
--   quien es titular (nfl_depth_chart 2026, los 32 equipos con RB1 y QB1)
--   cuantos acarreos mete su equipo dentro de la 5 (nfl_equipo_totales)
--   cuantos TD permite la defensa rival A ESA POSICION (nfl_defense_vs_position)
--
-- BUG MIO QUE ENCONTRE Y ARREGLE: la primera version tomaba una fila de
-- nfl_defense_vs_position sin filtrar por posicion, y salian cosas como
-- "yardas aereas permitidas: 0". No era un bug de los datos: esa tabla es
-- POR POSICION, y la fila de RB legitimamente tiene 0 yardas aereas. Yo
-- estaba tomando una posicion al azar. Ahora se cruza posicion con posicion.
--
-- NO PUBLICA UN PORCENTAJE, Y ESO ES DELIBERADO. RETO no tiene un modelo de
-- anotador de TD validado. Un "James Cook 38% de anotar" seria inventado.
-- Se publican los insumos con su temporada y un texto de como leerlos.
-- El dueno pidio "quien mete TD Y PORQUE": el porque es esto, verificable.
--
-- Ejemplo real (Buffalo - Detroit):
--   Bills: RB1 James Cook III, 43 acarreos dentro de la 5 en 2025
--   Defensa de Detroit permite 0.67 TD terrestres por juego a los RB (3 juegos)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Un lado del duelo de TD. Cruza posicion con posicion.
-- ---------------------------------------------------------------------
create or replace function public.nfl_td_lado(p_abrev text, p_rival_abrev text)
returns jsonb language sql stable as $fn$
  select jsonb_build_object(
    'titulares', (select jsonb_object_agg(d.posicion, d.jugador)
                  from public.nfl_depth_chart d
                  where d.temporada=2026 and d.equipo=p_abrev and d.orden=1
                    and d.posicion in ('QB','RB','WR','TE')),
    'volumen_zona_roja', (select jsonb_build_object(
          'temporada', t.temporada, 'fuente', t.fuente,
          'acarreos_dentro_de_la_5', t.rz5_acarreos,
          'acarreos_dentro_de_la_10', t.rz10_acarreos,
          'acarreos_dentro_de_la_20', t.rz20_acarreos,
          'pct_pase', t.pct_pase)
        from public.nfl_equipo_totales t where t.equipo=p_abrev
        order by t.temporada desc limit 1),
    'defensa_rival_permite_por_posicion', (
      select jsonb_object_agg(x.position, x.bloque)
      from (
        select distinct on (dv.position) dv.position,
               jsonb_build_object(
                 'temporada', dv.season, 'juegos', dv.games_played,
                 'td_terrestres_permitidos_total', dv.rush_tds_allowed,
                 'td_recepcion_permitidos_total', dv.rec_tds_allowed,
                 'td_terrestres_por_juego', case when dv.games_played>0
                    then round(dv.rush_tds_allowed::numeric/dv.games_played,2) end,
                 'td_recepcion_por_juego', case when dv.games_played>0
                    then round(dv.rec_tds_allowed::numeric/dv.games_played,2) end,
                 'yardas_terrestres_pg', nullif(dv.rush_yards_allowed_pg,0),
                 'yardas_aereas_pg', nullif(dv.pass_yards_allowed_pg,0)
               ) as bloque
        from public.nfl_defense_vs_position dv
        where dv.team=p_rival_abrev and dv.position in ('QB','RB','WR','TE')
        order by dv.position, dv.season desc
      ) x)
  );
$fn$;

create or replace function public.nfl_td_contexto(p_espn_event_id text)
returns jsonb language plpgsql stable as $fn$
declare p record;
begin
  select distinct on (x.espn_event_id) x.espn_event_id, x.home_abrev, x.away_abrev,
         x.home_team, x.away_team
    into p
  from public.nfl_partidos x where x.espn_event_id = p_espn_event_id
  order by x.espn_event_id, x.actualizado desc nulls last;

  if not found or p.home_abrev is null or p.away_abrev is null then
    return jsonb_build_object('status','SIN_DATOS_DE_EQUIPO',
      'note','No se pudo resolver la abreviatura de los equipos. No se inventa un candidato a TD.');
  end if;

  return jsonb_build_object(
    'status','AVAILABLE_FACTUAL_ONLY',
    'authority','FACTUAL_CONTEXT_NOT_P_RETO',
    'home', jsonb_build_object('equipo', p.home_team) || public.nfl_td_lado(p.home_abrev, p.away_abrev),
    'away', jsonb_build_object('equipo', p.away_team) || public.nfl_td_lado(p.away_abrev, p.home_abrev),
    'como_leerlo','Cruza tres cosas: quien es el titular en cada posicion, cuantos acarreos mete su equipo dentro de la 5 (ahi se anotan los TD terrestres), y cuantos TD permite la defensa rival A ESA POSICION. Un RB titular de un equipo con mucho volumen en la 5, contra una defensa que sangra TD terrestres a los RB, es el candidato natural.',
    'por_que_no_hay_porcentaje','RETO no tiene un modelo de anotador de TD validado. Un porcentaje aqui seria inventado. Se publican los insumos reales con su temporada, y la conclusion la saca quien lee.',
    'advertencia_de_muestra','Los totales de 2026 son de 1 a 3 juegos y NO son representativos; los de 2025 son de temporada completa. Cada bloque declara su temporada y sus juegos para que no se confundan.');
end $fn$;

revoke all on function public.nfl_td_lado(text,text) from public;
revoke all on function public.nfl_td_contexto(text) from public;
grant execute on function public.nfl_td_lado(text,text) to anon, authenticated, service_role;
grant execute on function public.nfl_td_contexto(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2) Conexion al contrato de NFL, guarda de exactamente 1.
-- ---------------------------------------------------------------------
DO $outer$
DECLARE v_def text; v_o text; v_n text; c int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='nfl_terminal_v2';
  v_o := $r$    'points_expectation',coalesce(public.puntos_esperados_contexto(p_event),'{}'::jsonb),
    'factors',v_factors,$r$;
  v_n := $r$    'points_expectation',coalesce(public.puntos_esperados_contexto(p_event),'{}'::jsonb),
    'td_context',coalesce(public.nfl_td_contexto(p_event),'{}'::jsonb),
    'factors',v_factors,$r$;
  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  IF c <> 1 THEN RAISE EXCEPTION 'ISS135 aborta: % coincidencias, se exigia 1', c; END IF;
  EXECUTE replace(v_def, v_o, v_n);
END
$outer$;

-- ---------------------------------------------------------------------
-- 3) Refresco de la tarjeta de MLB. La definicion de mv_tarjeta_mlb_v1
--    esta en produccion; se refresca cada 15 min.
-- ---------------------------------------------------------------------
-- select cron.schedule('tarjeta-mlb-refresh-15m', '3,18,33,48 * * * *',
--   $$refresh materialized view concurrently public.mv_tarjeta_mlb_v1;$$);

-- =====================================================================
-- MEDIDO:
--
-- GATE 31 (MLB), 8 duras, todas PASS sobre 103 juegos:
--   G31.1 total suma 100 con push ........... PASS  0
--   G31.2 linea entera TIENE push ........... PASS  0
--   G31.3 linea .5 NO tiene push ............ PASS  0
--   G31.4 NRFI + YRFI suman 100 ............. PASS  0
--   G31.5 F5 suma 100 con empate ............ PASS  0
--   G31.6 moneyline coherente ............... PASS  0
--   G31.7 ML etiquetado NO validado ......... PASS  0
--   G31.8 sin linea no se inventa ........... PASS  0
--   G31.9 cobertura ......................... INFO  103
--         40 con analisis | 15 con linea | 63 sin abridores anunciados
--
-- NFL, 20 partidos muestreados por el contrato completo:
--   20/20 con puntos esperados
--   20/20 con FPI de ambos equipos
--   20/20 con contexto de TD
--   20/20 con RB titular resuelto
-- =====================================================================
