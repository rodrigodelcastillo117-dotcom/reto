-- iss070 · "mi parlay nunca se calificó de NFL": dos razones, ninguna era el resolvedor.
--
-- AUTORIZADO POR EL OWNER el 2026-09-11 ("SII DALE A CABLEADO DEL RESOLVEDOR").
-- Esto escribe en el registro de dinero, así que se hizo con dry run primero y con
-- verificación de integridad del dato antes de emitir un solo veredicto.
--
-- EL PARLAY CONCRETO: fbb18adb (rodelcast, LAR - SF, 2026-09-10, -500, ya cerrado
-- como perdido con sus CUATRO patas en 'pendiente'). Es literalmente el caso
-- "parlay perdido sin ninguna pata perdedora" que el owner reclamó.
--
-- RAZÓN 1 — Los props de jugador no se podían calificar ni en principio.
-- evaluar_leg_parlay_v1 no recibe ningún parámetro de estadística de jugador. Para
-- "Christian McCaffrey (SF) 1+ Touchdowns" devolvía no_evaluable y la pata quedaba
-- colgada para siempre. nfl_prop_resolver (iss061) ya existía pero NO estaba cableado.
--
-- RAZÓN 2 — NINGÚN total de NFL se podía calificar. Esto no lo sabía nadie.
-- evaluar_leg_parlay_v1, línea 80, tiene un guardia:
--     IF d LIKE '%corner%' OR ... OR d LIKE '%points%' OR d LIKE '%puntos%' OR ...
--     THEN RETURN 'no_evaluable'; END IF;
-- El guardia está ahí para props de basquet (puntos/rebotes/asistencias). Pero en NFL
-- el TOTAL DEL PARTIDO también se mide en puntos. Verificado: con LAR 7 - SF 27
-- (total 34) y la pata "Menos de 50.5 puntos totales (incl. prórroga)",
-- evaluar_leg_parlay_v1 devuelve 'no_evaluable'. Un under que ganó por 16 puntos y
-- el sistema no podía decirlo.
--
-- POR QUÉ NO TOQUÉ ESE GUARDIA
-- Modificarlo podría cambiar calificaciones YA EMITIDAS de otros deportes, incluidas
-- las de basquet. En su lugar se añadió evaluar_total_juego_v1 como fallback que
-- devuelve NULL cuando no opina, siguiendo el patrón ya probado de
-- evaluar_juegos_tenis_v1. Así este cambio SOLO puede convertir un 'no_evaluable' en
-- veredicto; no puede pisar ninguno existente.
--
-- VERIFICACIÓN DE INTEGRIDAD ANTES DE TOCAR DINERO
-- nfl_player_game_logs decía McCaffrey 0 TDs, Adams 0 TDs, Stafford 0 pases de TD.
-- Antes de emitir tres 'perdido' comprobé que el dato cuadrara con el marcador real:
--   LAR: 1 TD terrestre, 0 pases de TD  -> 7 puntos = TD + patada. Cuadra con LAR 7.
--   SF:  3 TDs de recepción = sus 3 pases de TD (sin doble conteo) -> 21 + 2 goles
--        de campo (6) = 27. Cuadra con SF 27.
-- Dato internamente consistente Y consistente con el marcador final => los tres
-- veredictos 'perdido' son confiables. McCaffrey no anotó porque el único TD de LAR
-- fue terrestre de otro jugador y los 3 de SF fueron de recepción de otros.
--
-- MAPEO DE ESTADOS (esto es lo que protege el dinero)
-- nfl_prop_resolver devuelve jsonb con 'estado'. SOLO se aceptan dos:
--   GANADA  -> 'ganado'
--   PERDIDA -> 'perdido'
-- SIN_MAPEO, PENDIENTE, SIN_DATO_JUGADOR y AMBIGUO NO producen veredicto. "No hay
-- fila del jugador" NO significa "no anotó": puede ser que la fuente aún no publique.
-- En esos casos la pata sigue pendiente a propósito, y el jsonb del resolvedor se
-- guarda en la pata como 'prop_diagnostico' para poder verlo.
-- Cuando SÍ hay veredicto, el jsonb se guarda como 'prop_evidencia': de ahora en
-- adelante toda pata de prop calificada trae el valor, el umbral y la métrica con la
-- que se decidió. Se acabó el "perdió porque sí".
--
-- RESULTADO MEDIDO
--   dry run de fbb18adb: 4 patas, 1 ganada, 3 perdidas, 0 sin resolver.
--     "Menos de 50.5 puntos totales" -> ganado  (por total_juego_nfl, total 34)
--     McCaffrey 1+ TD                -> perdido (por prop_nfl, valor 0, umbral 1)
--     Davante Adams 1+ TD            -> perdido (por prop_nfl, valor 0, umbral 1)
--     Stafford 1+ pases de TD        -> perdido (por prop_nfl, valor 0, umbral 1)
--   aplicado en firme: el dinero NO se movió (-500, sigue 'perdido'), porque
--   auto_close_parlay_trigger no se activa si el parlay ya no está pendiente.
--   Solo se llenó el detalle. Que es exactamente lo que faltaba.
--
--   barrido completo autocalificar_parlays_pendientes(false): 6 parlays,
--   51 patas ganadas, 14 perdidas, 17 sin resolver. Los 6 ya estaban cerrados,
--   así que ninguno movió dinero.
--
-- LO QUE SIGUE SIN RESOLVERSE, Y POR QUÉ (contabilidad honesta de las 27 patas
-- pendientes que quedan en toda la base)
--   10 patas en 2 parlays con manual_lock = true y resultado = 'nulo'
--      (d3adc9fc con 8 moneylines de MLB del 2-sep, c9237cf6 con 2).
--      Los marcadores SÍ existen y son finales: Angels 3 - Yankees 6,
--      Astros 2 - White Sox 0, Cubs 5 - Brewers 9. Probé evaluar_leg_parlay_v1
--      directo sobre las tres y califica bien (ganado, ganado, perdido).
--      NO las toqué: manual_lock=true es una decisión humana explícita de
--      "no toques esto", y autocalificar_parlays_pendientes la respeta en
--      sus dos ramas. Si el owner quiere que se califiquen, hay que quitar
--      el lock a mano: es su decisión, no mía.
--      Nota: la rama B tampoco incluiría 'nulo' aunque no hubiera lock
--      (solo acepta ganado/perdido/push). Son dos exclusiones, no una.
--    9 patas de tenis en 861b03b9 (el parlay de -250 que el owner marcó).
--      Estado real: 16 patas -> 4 ganadas, 0 perdidas, 3 nulas, 9 pendientes.
--      Sigue sin haber una sola pata perdedora. Las 9 son moneylines de tenis
--      del 6-ago y buscar_marcador SÍ devuelve fila, pero con
--      home_score 0, away_score 0, sets NULL y status 'final'. Un registro basura.
--      is_truly_final correctamente se niega a calificar con eso: si no lo hiciera,
--      marcaría perdedores con un 0-0 inventado. El arreglo no está aquí, está en
--      la ingesta de resultados de tenis. QUEDA ABIERTO: por qué ese parlay se
--      cerró como perdido sin pata perdedora sigue sin explicación técnica.
--    4 patas de fútbol saudí con fecha de hoy: el partido no se ha jugado. Correcto.
--    2 patas "Los Angeles FC 1X2" con LAFC 1 - Querétaro 1 y status_detail 'PEN'.
--      Se decidió en penales. En 1X2 un 1-1 es empate (X), así que el pick perdería;
--      pero en Leagues Cup no existe el empate y el sistema tiene nota propia sobre
--      esto en construir_dossier_partido ('sin_empate'). NO lo adivino: es una
--      decisión de reglas que le toca al owner.
--    1 pata PSG - Slovan con espn_event_id 'af_1635705' (id de apifootball, no de
--      ESPN): no se puede buscar por id.
--
-- ORDEN DE APLICACIÓN
--  1) evaluar_total_juego_v1 (abajo, completa)
--  2) el recableado de sync_resultados_legs_parlay, que se hizo con cirugía de texto
--     sobre pg_get_functiondef EXIGIENDO que cada ancla apareciera exactamente 1 vez
--     (si aparece 0 o 2 veces, raise exception y no se toca nada).
--     El cuerpo vigente se recupera con:
--       select pg_get_functiondef(p.oid) from pg_proc p
--       join pg_namespace n on n.oid=p.pronamespace
--       where n.nspname='public' and p.proname='sync_resultados_legs_parlay';

create or replace function public.evaluar_total_juego_v1(
  p_pick_desc text,
  p_home_score int,
  p_away_score int,
  p_deporte text,
  p_status text,
  p_status_detail text
) returns text
language plpgsql
stable
as $$
declare
  d text := lower(public.unaccent(coalesce(p_pick_desc,'')));
  v_resto text;
  v_linea numeric;
  v_total int;
  v_over boolean;
  v_under boolean;
begin
  if p_home_score is null or p_away_score is null then return null; end if;

  -- Solo futbol americano. En futbol el total va en goles y ya lo resuelve
  -- evaluar_leg_parlay_v1; aqui no se mete.
  if coalesce(p_deporte,'') !~* 'football|americano|nfl|ncaaf' then return null; end if;

  -- Solo si el partido de verdad termino.
  if not public.is_truly_final(p_status, p_status_detail, null, null,
                               p_home_score, p_away_score, null, p_deporte) then
    return null;
  end if;

  -- Tiene que ser un TOTAL DEL PARTIDO, escrito como tal.
  if d !~ '(puntos totales|total de puntos|puntos en total)' then return null; end if;

  -- No puede ser prop de jugador: se rechaza el formato propio del sistema
  -- "Nombre Apellido (EQ) ..." y cualquier mencion explicita de jugador.
  if p_pick_desc ~ '\([A-Za-z]{2,4}\)' then return null; end if;
  if d ~ '(jugador|player|anotador|goleador|recepcion|yardas|touchdown)' then return null; end if;

  -- Direccion del mercado: una sola y sin ambiguedad.
  v_over  := d ~ '\mover\M' or d ~ '\mmas de\M' or d ~ '\mmayor a\M';
  v_under := d ~ '\munder\M' or d ~ '\mmenos de\M' or d ~ '\mmenor a\M';
  if v_over = v_under then return null; end if;

  -- La linea con regexp_match y NO regexp_replace(...,'[^0-9.]','') porque esa forma
  -- convierte "Menos de 50.5 puntos totales (incl. prorroga)" en "50.5." -- el punto
  -- de "incl." sobrevive y el cast truena. Mismo bug ya corregido en clv_capturar_cierre.
  v_linea := nullif((regexp_match(d, '(\d+(?:[.,]\d+)?)'))[1], '');
  if v_linea is null then return null; end if;

  -- Nada de texto sobrante: si queda algo alfabetico puede ser un total de EQUIPO
  -- ("Total puntos Rams mas de 24.5"), que NO es el total del partido. Se abstiene.
  v_resto := regexp_replace(d, '\d+(?:[.,]\d+)?', ' ', 'g');
  v_resto := regexp_replace(v_resto, '(puntos totales|total de puntos|puntos en total)', ' ', 'g');
  v_resto := regexp_replace(v_resto, '\m(over|under|mas|menos|mayor|menor|de|a|del|incl|prorroga|tiempo|extra|ot|total|totales|puntos)\M', ' ', 'g');
  v_resto := btrim(regexp_replace(v_resto, '[^a-z]', '', 'g'));
  if v_resto <> '' then return null; end if;

  v_total := p_home_score + p_away_score;

  -- Empate exacto contra la linea: evaluar_leg_parlay_v1 lo trata como 'no_evaluable'
  -- en el resto de mercados. Se devuelve NULL para no inventar semantica de push.
  if v_total = v_linea then return null; end if;

  if v_over then
    return case when v_total > v_linea then 'ganado' else 'perdido' end;
  else
    return case when v_total < v_linea then 'ganado' else 'perdido' end;
  end if;
end;
$$;

-- PRUEBAS QUE PASÓ (12 de 12, incluidas las 8 abstenciones):
--   Under 50.5 / total 34  -> ganado     Under 30.5 / total 34 -> perdido
--   Over 30.5  / total 34  -> ganado     Over 50.5  / total 34 -> perdido
--   prop de jugador con (SF)            -> NULL
--   "yardas recibidas puntos totales"   -> NULL
--   "Total puntos Rams menos de 24.5"   -> NULL  (total de equipo, no del partido)
--   basquet 99-101 "Menos de 210.5"     -> NULL  (deporte no aplica)
--   futbol "Menos de 2.5 goles"         -> NULL
--   empate exacto con la linea          -> NULL
--   sin direccion / sin linea           -> NULL
--   status 'in' (en vivo) y 'scheduled' -> NULL
--   marcador NULL                       -> NULL
