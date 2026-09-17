-- ISS165: el 401 que vaciaba la tarjeta, y tres cosas que la tarjeta mentia
--
-- ================================================================
-- 1. LA CAUSA REAL DE QUE NO SE PINTARA NADA: 401 POR PERMISOS
-- ================================================================
-- Lovable lo midio con la llave publica y lo clavo:
--     select=espn_event_id        200
--     select=ganador_pct          200
--     select=btts_si_pct          200
--     select=over_pct             401  permission denied for soccer_stats_partido
--     select=calibracion_estado   401  permission denied for calibracion_over_under
--     select=*                    401
--
-- La vista NO era el problema (reloptions null: corre como su dueno). El
-- problema eran DOS FUNCIONES que la vista llama y que corrian como QUIEN
-- CONSULTA, no como su dueno:
--
--   public.ou_por_tiros_tarjeta   -> toca v2.ou_tarjeta_cache.   MIA, de anoche.
--   public.soccer_ou_calibrado    -> toca v2.calibracion_over_under.  YA EXISTIA.
--
-- La segunda es la importante: lleva tumbando el `select *` desde ANTES de que
-- yo tocara nada. Por eso el bloque de la tarjeta nunca se pinto, ni siquiera
-- con el cerebro viejo. Yo solo agregue una segunda causa encima.
--
-- ARREGLO: las dos a SECURITY DEFINER con search_path fijo. NO se dio grant
-- sobre las tablas base: eso expondria las tablas enteras. Asi el que consulta
-- recibe exactamente la salida de la funcion y cero acceso a las tablas.
--
--   alter function public.ou_por_tiros_tarjeta(text,numeric)
--     security definer set search_path = public, v2, pg_temp;
--   alter function public.soccer_ou_calibrado(...)
--     security definer set search_path = public, v2, pg_temp;
--
-- ================================================================
-- 2. RENDIMIENTO: LA VISTA SE HABIA VUELTO LENTA, Y ERA YO
-- ================================================================
-- En ISS161 puse una llamada a ou_por_tiros_tarjeta en over_pct y under_pct, y
-- en ISS163 anadi una tercera en linea_estado. La funcion era plpgsql y hacia
-- dos consultas de ventana sobre los tiros CADA VEZ. 150 tarjetas x 3 llamadas.
--
--   antes de tocar nada   1226 ms
--   despues de ISS163     se agotaba la conexion
--   con la cache           602 ms   <- la mitad que el original
--
-- ARREGLO: v2.ou_tarjeta_cache (tabla), v2.refrescar_ou_tarjeta() y cron
-- 'ou-tarjeta-cache' cada 5 minutos. ou_por_tiros_tarjeta pasa a ser SQL puro
-- que lee la tabla. Misma salida: 134 tarjetas con altas/bajas, igual que antes.
--
-- LECCION: una funcion plpgsql llamada fila por fila dentro de una vista
-- publicada es una bomba de tiempo. No se nota con 10 filas y mata con 150.
--
-- ================================================================
-- 3. EL AVISO ROJO MENTIA EN LAS 146 TARJETAS
-- ================================================================
-- Todas decian: "Sobre 150 partidos reales este mercado sale PEOR que adivinar,
-- y el intervalo de confianza del 95% esta entero por encima de cero."
--
-- Eso era verdad DEL CEREBRO VIEJO, el que reemplace en ISS161. Se seguia
-- recalculando (ultima corrida 06:44 de hoy) sobre las observaciones de
-- crossleague_v1 y se pintaba al lado del numero del cerebro NUEVO. O sea: la
-- tarjeta difamaba a su propio numero, en las 146.
--
-- ARREGLO en public.v_evidencia_mercado_soccer: el mercado 'total' pasa a
-- veredicto SIN_VEREDICTO_CEREBRO_NUEVO con el texto honesto completo, que dice
-- las tres cosas: que se reemplazo, que el anterior salia peor que adivinar, y
-- que el nuevo gano fuera de muestra pero todavia NO acumula resultados en vivo
-- para calificarlo ahi. Ni se oculta el pasado ni se le cuelga al nuevo.
--
-- ================================================================
-- 4. EL PICK SE DESEMPATABA SOLO, EN SILENCIO
-- ================================================================
-- Besiktas vs Marseille: local 38.8% y visita 38.8%, exactamente iguales.
-- El CASE del ganador_pick usaba >= :
--     WHEN p_home >= p_draw AND p_home >= p_away THEN home
-- Con empate exacto las dos condiciones se cumplen y se quedaba con el LOCAL.
--
-- La tarjeta renderizada mostraba las dos cosas a la vez: "Sin pick publicable
-- por ahora" (el selector canonico del frontend SI respeta la regla) y debajo
-- "GANA 38.8% Besiktas" con sello verde de validado. Dos cerebros, dos
-- respuestas, misma tarjeta. Justo lo prohibido.
--
-- ARREGLO: > en vez de >=, y una rama previa que devuelve NULL si hay CUALQUIER
-- empate arriba. Si no hay un ganador estricto, no hay pick. Hoy: 1 tarjeta.
--
-- ================================================================
-- LO QUE NO SE ARREGLA AQUI, A PROPOSITO
-- ================================================================
-- El empate sale con DOS numeros en 120 de 146 tarjetas: 24.8% en la
-- distribucion 1X2 y 25.4% en el margen. Peor diferencia medida: 1.80 puntos.
--
-- CAUSA, ya localizada: en el CTE 'margen' los siete tramos se dividen por
-- NULLIF(sum(x.p), 0), o sea se renormalizan sobre la masa que la distribucion
-- de marcadores alcanza a medir, que es 90.7% a 92%. Cada tramo queda inflado
-- ~10% relativo.
--
-- POR QUE NO LO PARCHEO HOY: el arreglo correcto es extender la cobertura de
-- score_dist, que es un cambio de modelo. Quitar el denominador deja los tramos
-- sumando 91. Anclar el empate a p_draw cuadra un numero y descuadra los otros
-- seis. Las dos son trampas que dejan la tarjeta peor. Son <=1.8 puntos y no
-- cambian ningun pick. Va con su propia medicion, no de madrugada despues de
-- una noche entera cambiando produccion.
--
-- ================================================================
-- ABIERTO
-- ================================================================
-- G34.1 en FAIL: un trabajo muerto acaparando la cola, KV Kortrijk con 87
-- intentos. Es de la cola de equipos, no de las tarjetas. Sin tocar.

alter function public.ou_por_tiros_tarjeta(text, numeric)
  security definer set search_path = public, v2, pg_temp;

do $$
declare r record;
begin
  for r in select p.oid::regprocedure sig from pg_proc p
           join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='soccer_ou_calibrado'
  loop
    execute format('alter function %s security definer set search_path = public, v2, pg_temp', r.sig);
  end loop;
end $$;

-- COMPROBACION
--   Con la llave publica: select=* sobre v_tarjeta_soccer_v1 debe dar 200.
--   select count(*) from v_tarjeta_soccer_v1 where over_pct is not null;  -> 134
--   select mercado_tarjeta, veredicto from v_evidencia_mercado_soccer;
--     total -> SIN_VEREDICTO_CEREBRO_NUEVO
--   select count(*) from v_tarjeta_soccer_v1
--     where ganador_pick is null and estado='CON_P_RETO';  -> 1 (Besiktas)
