-- ISS145: la ingesta de resultados de futbol llevaba dias caida EN SILENCIO.
--
-- COMO SE ENCONTRO
-- El dueno pregunto si se guardan los resultados reales de los partidos. Al ir
-- a medirlo en vez de contestarlo de memoria, aparecio esto:
--
--   ultimo marcador de futbol guardado ... 2026-09-15 01:00
--   hora real al medir .................. 2026-09-17 01:12
--   partidos del 16-sep ya jugados ...... 16
--   de esos, con marcador guardado ...... 0
--
-- LA CAUSA
-- ESPN dejo de aceptar el parametro de RANGO de fechas:
--
--   .../scoreboard?limit=400&dates=20260914-20260917
--   -> 400 {"code":400,"message":"Failed to get events endpoint."}
--
-- Y rechaza CUALQUIER rango, incluido el de 150 dias que usaba en produccion
-- public.pedir_historico_reciente(150), llamado por el cron 294 todos los dias
-- a las 04:05. Se comprobo con la misma liga y tres formatos a la vez:
--
--   dates=20260420-20260917 (150 dias, el de produccion) .. 400
--   dates=20260914-20260917 (3 dias) ...................... 400
--   dates=20260914          (un dia) ...................... 200, 1 evento
--   dates=202609            (mes completo) ................ 200, 30 eventos
--   sin parametro dates ................................... 200, 1 evento
--
-- POR QUE NADIE SE ENTERO
-- El cron marcaba "succeeded" en cron.job_run_details porque el SQL corria
-- bien: encolaba 58 peticiones con net.http_get y devolvia 58. Lo que fallaba
-- era el HTTP, despues, de forma asincrona. absorber_historico_espn() solo
-- contaba las respuestas 200 y devolvia partidos_nuevos=0 sin decir por que.
-- Nadie miraba el status_code. El modelo se quedo ciego y el tablero verde.
--
-- EL ARREGLO
--   1. public.pedir_historico_meses(p_meses) pide por MES ("dates=AAAAMM"),
--      que es el formato que ESPN si acepta. Una peticion por liga y por mes.
--   2. public.pedir_historico_reciente(p_dias) conserva su firma (el cron 294
--      la llama con 150) pero por dentro convierte dias a meses y delega.
--   3. public.refrescar_resultados_recientes(p_meses) hace un ciclo completo:
--      absorbe lo que contesto la tanda anterior y deja pedida la siguiente.
--      Cron nuevo 'resultados-soccer-cada-hora' a las :38 de cada hora, con el
--      mes en curso. El marcador de anoche entra en menos de una hora, no en 24.
--   4. absorber_historico_espn() ahora CUENTA las respuestas no-200 y levanta
--      alerta en public.alertas_sistema (CRITICA si fallaron todas).
--   5. GATE 35 nuevo: mide frescura, no causa. Si la descarga se vuelve a caer
--      por cualquier motivo, se pone rojo solo.
--
-- LO QUE SE RECUPERO AL CORRERLO
--   peticiones mes en curso .... 58/58 en 200 -> 61 partidos nuevos
--   peticiones 6 meses ......... 348/348 en 200 -> 54 partidos nuevos
--   total recuperado ........... 115 partidos
--
--   16-sep: 0 -> 23 partidos con marcador
--   15-sep: 1 -> 27 partidos con marcador
--   atraso del ultimo resultado: de ~48 horas a 3.3 horas
--
--   build_soccer_prediction_v2() -> 211 | tarjetas 212 | con P_RETO 146
--   tarjetas perdidas por el cambio: 0
--
-- GATE 35 al instalar: G35.1 PASS (3h) | G35.2 PASS (0) | G35.3 PASS (0)

-- ---------------------------------------------------------------------------
-- 1. PEDIR POR MES (el formato que ESPN si acepta)
-- ---------------------------------------------------------------------------
create or replace function public.pedir_historico_meses(p_meses integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_n int; v_pendientes int;
begin
  -- 2026-09-17: ESPN DEJO DE ACEPTAR EL RANGO "dates=AAAAMMDD-AAAAMMDD".
  -- Devuelve 400 "Failed to get events endpoint" para CUALQUIER rango, incluido
  -- el de 150 dias que usaba pedir_historico_reciente. Por eso la ingesta de
  -- resultados de futbol llevaba dias cayendose sin que nadie se enterara: el
  -- cron marcaba "succeeded" porque el SQL corria bien; lo que fallaba era el
  -- HTTP, y nadie miraba el status.
  --
  -- El formato que SI acepta es el mes completo: "dates=AAAAMM". Devuelve el mes
  -- entero, terminados con marcador y los que vienen. Una peticion por liga y
  -- por mes cubre todo.
  select count(*) into v_pendientes from public._carga_historico;
  if v_pendientes > 0 then
    return jsonb_build_object('peticiones', 0, 'motivo', 'YA_HAY_EN_VUELO', 'pendientes', v_pendientes);
  end if;

  insert into public._carga_historico (req_id, espn_endpoint, liga_id, rango)
  select net.http_get(
           'https://site.web.api.espn.com/apis/site/v2/sports/' || l.espn_endpoint
           || '/scoreboard?limit=400&dates=' || to_char(m.mes,'YYYYMM')),
         l.espn_endpoint, l.api_sports_id, to_char(m.mes,'YYYYMM')
  from public.ligas_master l
  cross join lateral (
    select generate_series(
             date_trunc('month', current_date) - ((greatest(p_meses,1)-1) || ' months')::interval,
             date_trunc('month', current_date),
             interval '1 month') as mes
  ) m
  where (l.activa or l.historico_activo) and l.espn_endpoint like 'soccer/%' and l.espn_blocked is not true;

  get diagnostics v_n = row_count;
  return jsonb_build_object('peticiones', v_n, 'meses', greatest(p_meses,1));
end
$function$;

-- ---------------------------------------------------------------------------
-- 2. LA DE SIEMPRE, AHORA DELEGANDO (el cron 294 la llama con 150)
-- ---------------------------------------------------------------------------
create or replace function public.pedir_historico_reciente(p_dias integer default 60)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_meses int;
begin
  -- Se conserva la firma en dias porque el cron 294 la llama con 150, pero por
  -- dentro pide por MES, que es el formato que ESPN si acepta desde 2026-09-17.
  v_meses := greatest(1, ceil(greatest(p_dias,1)::numeric / 30.0)::int);
  delete from public._carga_historico;
  return public.pedir_historico_meses(v_meses) || jsonb_build_object('dias_pedidos', p_dias);
end
$function$;

-- ---------------------------------------------------------------------------
-- 3. CICLO HORARIO: absorbe lo anterior, pide lo siguiente
-- ---------------------------------------------------------------------------
drop function if exists public.refrescar_resultados_recientes(integer);
create or replace function public.refrescar_resultados_recientes(p_meses integer default 1)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_absorbido jsonb; v_pedido jsonb;
begin
  v_absorbido := public.absorber_historico_espn();
  v_pedido    := public.pedir_historico_meses(p_meses);
  return jsonb_build_object('absorbido', v_absorbido, 'pedido', v_pedido, 'corrio_at', now());
end
$function$;

select cron.schedule('resultados-soccer-cada-hora', '38 * * * *',
  $$select public.refrescar_resultados_recientes(1);$$);

-- ---------------------------------------------------------------------------
-- 4. EL ABSORBEDOR YA NO SE TRAGA LOS ERRORES
-- ---------------------------------------------------------------------------
-- (cuerpo completo instalado en produccion; el cambio es el bloque que cuenta
--  las respuestas != 200 y escribe en public.alertas_sistema con gravedad
--  CRITICA cuando respuestas_ok = 0, y la clave nueva 'respuestas_fallidas'
--  en el jsonb que devuelve.)

-- ---------------------------------------------------------------------------
-- 5. GATE 35: MIDE FRESCURA, NO CAUSA
-- ---------------------------------------------------------------------------
--   G35.1  el ultimo resultado de futbol no tiene mas de 36 horas
--   G35.2  todo partido de liga mapeada que termino hace +6h tiene marcador
--   G35.3  ESPN no esta rechazando las peticiones del lote en curso
--   G35.4  INFO: alertas de ingesta sin ver
--
-- El punto de G35 es que NO depende de que se rompio. Si manana ESPN cambia
-- otra vez el endpoint, o cambia la llave, o se cae la red, el gate se pone
-- rojo igual, porque mide el dato, no el camino.
