-- iss071 · Props: tres bugs y una mentira estadística.
--
-- El owner pidió "las 2 mejores props por equipo, basado en % que pase... mejoremos
-- eso a un 1000%". Al verificar lo que ya estaba publicado encontré esto:
--
-- BUG 1 — La vista se llamaba "top_por_equipo" y NO filtraba por equipo.
-- Calculaba rn_equipo con row_number() pero devolvía TODAS las filas y dependía de
-- que cada consumidor se acordara de filtrar. Medido el 2026-09-11: 161 filas, hasta
-- 8 por equipo (cuando se creó eran 64; crece conforme entran más game logs). Le
-- había dicho a Lovable "64 filas, exactamente 2 por equipo", y ya era falso.
-- ARREGLO: el filtro rn_equipo <= 2 vive ahora DENTRO de la vista. 64 filas, 32
-- equipos, max_rn = 2. El nombre de la vista ya es cierto.
--
-- BUG 2 — 52 jugadores en el equipo equivocado. El equipo salía de max(team).
-- max() devuelve el equipo ALFABÉTICAMENTE mayor, no el actual. Medido: 104
-- jugadores tienen más de un equipo en sus logs y max(team) le erra a 52 de ellos
-- (la mitad exacta). Un jugador en la tarjeta del equipo equivocado sale también
-- con el RIVAL equivocado, porque rival se deriva de equipo.
-- (Dos que revisé a mano, Isaiah Likely BAL->NYG y Greg Dortch ARI->DET, salían
--  bien por pura suerte alfabética. El bug es real igual.)
-- ARREGLO: CTE `actual` con DISTINCT ON (espn_player_id) ORDER BY game_date DESC.
-- El equipo y la posición salen del último partido jugado. Lo mismo para posicion.
--
-- BUG 3 — La ventana de 10 partidos cruza temporadas en silencio.
-- Medido: 37 de las 64 props (58%) se calculan con un último partido de hace MÁS
-- de 60 días, hasta 280 días. Jaylen Warren a "94.4% OVER 1.5 recepciones" con
-- partidos de enero, para un juego de septiembre. Con la semana 1 apenas jugada no
-- hay muestra de la temporada actual, así que usar la anterior es lo único posible
-- y es práctica legítima. El pecado era no decirlo.
-- ARREGLO: se exponen `ultimo_log`, `primer_log_usado`,
-- `dias_desde_ultimo_partido` y `dato_de_temporada_anterior` (bool, > 60 días antes
-- del kickoff) para que el front lo avise en la tarjeta.
--
-- LA MENTIRA ESTADÍSTICA — "100%".
-- `probabilidad` era la frecuencia cruda n_hit/n. Ty Johnson acertó 9 de 9 en
-- recepciones OVER 1.5, así que la app anunciaba 100%. Eso NO es una probabilidad,
-- es una frecuencia con n=9. Decirle al usuario "100% de que pase" es mentirle, y es
-- exactamente la clase de cosa que lo deja mal con sus amigos.
-- ARREGLO, con tres números en lugar de uno:
--   probabilidad        = estimador de Jeffreys (x+0.5)/(n+1). Estándar para una
--                         proporción. NUNCA devuelve 100%: 9 de 9 -> 95.0%.
--   probabilidad_cruda  = la frecuencia tal cual, para transparencia total.
--   prob_piso_95        = cota inferior de Wilson al 95%: el piso creíble.
--   aciertos / muestra  = la evidencia desnuda, "9/9", para que se pueda juzgar.
-- Y SE ORDENA POR EL PISO DE WILSON, no por la tasa cruda. Eso es lo que impide que
-- una muestra chica perfecta le gane a una grande y sólida:
--   9 de 9   -> cruda 100.0  jeffreys 95.0  piso 70.1
--   26 de 30 -> cruda  86.7  jeffreys 85.5  piso 70.3   <- gana, y debe ganar
--   8 de 8   -> cruda 100.0  jeffreys 94.4  piso 67.6
--   7 de 10  -> cruda  70.0  jeffreys 68.2  piso 39.7
--   0 de 9   -> cruda   0.0  jeffreys  5.0  piso  0.0
--
-- LO QUE NO CAMBIÉ, A PROPÓSITO
-- La compuerta de candidatos sigue siendo cruda >= 60 y n >= 8, idéntica a antes,
-- para no alterar qué props entran. Solo cambió lo que se MUESTRA y cómo se ORDENA.
-- Endurecer la compuerta (p.ej. exigir piso_95 >= 50) es una decisión del owner.
-- Nota: con la compuerta actual el piso mínimo entre las 64 es 31.3%, así que hay
-- props en el top 2 de su equipo cuya evidencia es genuinamente flaca. Ahora se ve.
--
-- El filtro de relevancia por métrica (mediana >= umbral) se conserva tal cual: es
-- lo que evita el artefacto "suplente UNDER 1.5 recepciones al 100%", que es verdad
-- solo porque el jugador nunca atrapa nada.
--
-- Lectura como anon: 0.003s. Refresco: cron job 422, refrescar_props_top(), cada 6h.

-- Las dos funciones de estadística. Parámetros en NUMERIC a propósito: count(*)
-- devuelve bigint y sqrt() devuelve double precision; round(double precision, int)
-- no existe en Postgres y ya me tropecé con eso dos veces en esta sesión.
create or replace function public.prop_wilson_piso(p_aciertos numeric, p_n numeric, p_z numeric default 1.96)
returns numeric language sql immutable as $$
  select case when coalesce(p_n,0) <= 0 then null else
    greatest(0::numeric, least(1::numeric,
      ( (p_aciertos/p_n) + (p_z*p_z)/(2*p_n)
        - p_z * sqrt( (((p_aciertos/p_n) * (1 - p_aciertos/p_n)) + (p_z*p_z)/(4*p_n))/p_n )::numeric
      ) / (1 + (p_z*p_z)/p_n)
    ))
  end;
$$;

create or replace function public.prop_jeffreys(p_aciertos numeric, p_n numeric)
returns numeric language sql immutable as $$
  select case when coalesce(p_n,0) <= 0 then null else (p_aciertos + 0.5)/(p_n + 1) end;
$$;

-- La vista materializada completa se aplicó vía execute_sql (apply_migration hace
-- rollback silencioso en este proyecto). Se recupera con:
--   select pg_get_viewdef('public.nfl_props_top_por_equipo'::regclass, true);
-- Después de recrearla hay que volver a otorgar lectura, EN SU PROPIA LLAMADA:
--   grant select on public.nfl_props_top_por_equipo to anon, authenticated;

-- COLUMNAS NUEVAS PARA EL FRONT (las viejas siguen todas, con el mismo nombre):
--   probabilidad_cruda           numeric   la frecuencia tal cual
--   prob_piso_95                 numeric   piso creíble al 95% (criterio de orden)
--   aciertos                     int       numerador de la evidencia
--   ultimo_log                   date      último partido usado
--   primer_log_usado             date      más antiguo de la ventana
--   dias_desde_ultimo_partido    int
--   dato_de_temporada_anterior   boolean   true si ultimo_log < kickoff - 60 dias
