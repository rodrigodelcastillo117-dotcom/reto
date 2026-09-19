-- ISS258 — Over/Under retirado tambien del API publica (futbol).
--
-- CONTEXTO: el mercado de totales de futbol esta RETIRADO desde el 17-sep-2026
-- por evidencia (Brier 0.5436 / 0.5424 contra 0.5 de adivinar; IC95 entero por
-- encima de cero en los dos caminos). `v_tarjeta_soccer_v1` ya lo sirve NULL.
-- `canonicalPick.ts` ya lo bloquea en el frontend. Pero el API seguia
-- entregandolo.
--
-- MEDIDO ANTES (2026-09-19):
--   v_futpro_publication_v3 : 97 filas, 94 con p_over y 94 con p_under
--   v_futpro_v2             : 147 filas, 94 con p_over y 94 con p_under
--   Las dos legibles por anon Y authenticated.
--
-- v_futpro_publication_v3 lee FROM v_futpro_v2 y pasa p_over/p_under/mejor_pick
-- tal cual. Su UNICO dependiente es v3. Por eso se arregla en v_futpro_v2 y
-- baja solo a las dos.
--
-- ERAN TRES FUGAS, NO UNA:
--   1. columnas p_over / p_under
--   2. `mejor_pick`: su argmax incluia las tuplas ('Mas de X goles', p_over) y
--      ('Menos de X goles', p_under), por eso mejor_pick nombraba un mercado
--      retirado en 64 de 121 filas
--   3. el jsonb `markets`: llevaba over_current, under_current, over25,
--      under25, over35, under35, over45, under45
--
-- QUE SE CONSERVA (contexto factual, NO prediccion):
--   over_line, odds_over, odds_under, line_source. Son la linea y los momios de
--   la casa: hechos, no pronosticos de RETO. La tarjeta ya los rotula
--   "referencia factual, sin probabilidad publicada".
--
-- QUE **NO** SE TOCA:
--   - BTTS / GG: NO esta retirado. Esta SIN VEREDICTO (muestra insuficiente),
--     que es distinto. Sigue publicandose con su insignia de evidencia.
--   - MLB y NFL: su Over/Under tiene evidencia propia y se mide aparte. No se
--     retira futbol y de paso otros deportes.
--   - v2.soccer_prediction_v2 ni ninguna tabla de backtest: ahi viven los
--     numeros que DEMOSTRARON que habia que retirar el mercado. Borrarlos seria
--     destruir la evidencia del propio retiro.
--
-- METODO: parche exactamente-una-vez sobre pg_get_viewdef. Si un ancla no
-- aparece exactamente 1 vez, el DO entero aborta y no se aplica nada.
-- Rollback: shadow-patches/iss258/rollback_ou_api_publica.sql

do $iss258$
declare
  src   text;
  nuevo text;
  n     int;

  anclas text[] := array[
    -- 1. columna p_over
    'WHEN g.rdy THEN p.p_over',
    -- 2. columna p_under
    'WHEN g.rdy THEN p.p_under',
    -- 3. jsonb markets: over_current / under_current
    '''over_current'', p.p_over, ''under_current'', p.p_under',
    -- 4-9. jsonb markets: over25/under25/over35/under35/over45/under45
    'WHEN p.over_line = 2.5 THEN p.p_over',
    'WHEN p.over_line = 2.5 THEN p.p_under',
    'WHEN p.over_line = 3.5 THEN p.p_over',
    'WHEN p.over_line = 3.5 THEN p.p_under',
    'WHEN p.over_line = 4.5 THEN p.p_over',
    'WHEN p.over_line = 4.5 THEN p.p_under',
    -- 10. mejor_pick: las dos tuplas de O/U dentro del argmax
    ', ((''Más de ''::text || p.over_line) || '' goles''::text,p.p_over), ((''Menos de ''::text || p.over_line) || '' goles''::text,p.p_under)) m(label, prob)'
  ];
  reemplazos text[] := array[
    'WHEN false THEN p.p_over',
    'WHEN false THEN p.p_under',
    '''over_current'', NULL::numeric, ''under_current'', NULL::numeric',
    'WHEN false THEN p.p_over',
    'WHEN false THEN p.p_under',
    'WHEN false THEN p.p_over',
    'WHEN false THEN p.p_under',
    'WHEN false THEN p.p_over',
    'WHEN false THEN p.p_under',
    ') m(label, prob)'
  ];
  i int;
begin
  src := pg_get_viewdef('public.v_futpro_v2'::regclass, true);
  nuevo := src;

  for i in 1 .. array_length(anclas, 1) loop
    n := (length(nuevo) - length(replace(nuevo, anclas[i], ''))) / length(anclas[i]);
    if n <> 1 then
      raise exception 'ISS258 ABORTA: el ancla %  aparece % veces, se esperaba exactamente 1. No se aplico nada.', i, n;
    end if;
    nuevo := replace(nuevo, anclas[i], reemplazos[i]);
  end loop;

  -- Cinturon y tirantes: despues del parche no puede quedar NINGUNA ruta viva
  -- que lleve p_over/p_under a la superficie.
  n := (length(nuevo) - length(replace(nuevo, 'WHEN g.rdy THEN p.p_over', ''))) / length('WHEN g.rdy THEN p.p_over');
  if n <> 0 then
    raise exception 'ISS258 ABORTA: quedaron % rutas vivas de p_over.', n;
  end if;

  execute 'create or replace view public.v_futpro_v2 as ' || nuevo;
end
$iss258$;

comment on view public.v_futpro_v2 is
  'ISS258: Over/Under RETIRADO como prediccion (evidencia 17-sep-2026). p_over/p_under siempre NULL, mejor_pick ya no puede nombrar un total, y el jsonb markets no lleva over*/under*. Se conservan over_line/odds_over/odds_under como contexto factual de la casa. BTTS/GG NO esta retirado: esta sin veredicto y se sigue publicando.';
