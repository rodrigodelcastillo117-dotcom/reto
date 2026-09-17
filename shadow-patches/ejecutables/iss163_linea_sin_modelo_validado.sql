-- ISS163: un estado nuevo para la linea que no tiene modelo validado
--
-- DANO COLATERAL QUE YO CAUSE EN ISS161, ENCONTRADO LEYENDO EL FRONTEND
--   El adaptador del frontend (src/v2/adapters/tarjetaSoccer.ts) tiene una
--   funcion detectarAnomalia con esta regla:
--
--     if (lineaEstado === 'LINEA_REAL_DEL_PARTIDO') {
--        if (overPct === null)
--          return "La base no publica la probabilidad de la linea real...";
--     }
--
--   Y una anomalia NO apaga solo el bloque de altas/bajas: apaga los
--   porcentajes de TODA la tarjeta.
--
--   Antes de ISS161 eso nunca pasaba, porque el cerebro viejo siempre daba un
--   numero. Al cambiarlo, 6 tarjetas quedaron diciendo "hay linea real del
--   partido" y sin probabilidad, o sea marcadas como rotas:
--     Bayern Munich vs Union Berlin      (linea 4.5, no validada)
--     Inter Miami vs San Diego           (linea 4.5, no validada)
--     Molde vs Aalesund                  (linea 4.5, no validada)
--     Getafe vs Malaga                   (linea 1.5, no validada)
--     Aris vs Iraklis                    (linea 2.5, sin muestra de tiros)
--     Kalamata vs Panathinaikos          (linea 2.5, sin muestra de tiros)
--
--   No lo detecto ningun gate porque no es un defecto de datos: es que el
--   estado que publicaba era MENTIRA. Decia "tengo la linea real" cuando lo
--   cierto es "tengo la linea real pero no tengo modelo validado para ella".
--
-- ARREGLO: decir la verdad en el estado, no tapar el hueco
--   Se anade el estado LINEA_SIN_MODELO_VALIDADO. El frontend solo dispara la
--   anomalia cuando el estado es exactamente LINEA_REAL_DEL_PARTIDO, asi que
--   con el estado nuevo simplemente no pinta altas/bajas y deja intacto el
--   resto de la tarjeta. No hizo falta cambiar una linea de frontend.
--
--   Que significa cada estado ahora:
--     LINEA_REAL_DEL_PARTIDO      hay linea de casa Y hay probabilidad probada
--     LINEA_SIN_MODELO_VALIDADO   hay linea de casa, NO hay modelo que la haya
--                                 pasado (lineas 1.5 y 4.5, o falta muestra de
--                                 tiros de alguno de los dos equipos)
--     SIN_LINEA_DE_CASA           no hay linea; nunca se inventa una
--
-- ANTES Y DESPUES (146 tarjetas con P_RETO)
--                                  antes            despues
--   LINEA_REAL_DEL_PARTIDO      140 (6 sin numero)  134 (0 sin numero)
--   LINEA_SIN_MODELO_VALIDADO     -                   6
--   SIN_LINEA_DE_CASA             6                   6
--
--   Tarjetas que el frontend habria apagado por anomalia: 6 -> 0.
--
-- LECCION
--   Cambiar de donde sale un numero no es solo cambiar el numero: hay que
--   revisar quien lo lee y que supone de el. Esto lo encontre leyendo el
--   adaptador del frontend, no ejecutando un gate. Los gates miran los datos;
--   nadie estaba mirando el contrato entre la vista y quien la consume.

do $mig$
declare v_def text; v_o text; v_n text; c int;
begin
  v_def := pg_get_viewdef('public.v_tarjeta_soccer_v1'::regclass);

  v_o := '            WHEN (pr.over_line IS NULL) THEN ''SIN_LINEA_DE_CASA''::text
            ELSE ''LINEA_REAL_DEL_PARTIDO''::text';
  v_n := '            WHEN (pr.over_line IS NULL) THEN ''SIN_LINEA_DE_CASA''::text
            WHEN (public.ou_por_tiros_tarjeta(e.espn_event_id, pr.over_line) IS NULL) THEN ''LINEA_SIN_MODELO_VALIDADO''::text
            ELSE ''LINEA_REAL_DEL_PARTIDO''::text';

  c := (length(v_def)-length(replace(v_def, v_o, '')))/length(v_o);
  if c <> 1 then raise exception 'ISS163: esperaba 1 ocurrencia, encontre %', c; end if;

  execute 'create or replace view public.v_tarjeta_soccer_v1 as ' || replace(v_def, v_o, v_n);
end
$mig$;

-- COMPROBACION
--   select linea_estado, count(*), count(*) filter (where over_pct is null)
--   from public.v_tarjeta_soccer_v1 where estado='CON_P_RETO' group by 1;
--   LINEA_REAL_DEL_PARTIDO no puede tener ni una fila sin numero.
