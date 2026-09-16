-- =====================================================================
-- ISS130 -- LA INGESTA LLEVABA 6 DIAS MUERTA POR UN STATEMENT TIMEOUT
--
-- SINTOMA: v2.soccer_coverage_job no movia un solo registro desde el
--          2026-09-10. 91 equipos PENDING, 5 RETRY, attempts=0 en muchos.
--          Sin ingesta no hay historial domestico; sin historial no hay
--          phi; sin phi el modelo se niega a predecir; y el usuario ve
--          "Datos del evento insuficientes" en Everton-Wolves.
--
-- POR QUE NO SE VEIA:
--   cron 420 (cada 5 min) -> v2.kick_soccer_global_backfill()
--     -> edge soccer-global-backfill-kick   devuelve 202 {"ok":true,"accepted":true}
--        y dispara soccer-global-backfill con waitUntil, FIRE AND FORGET:
--            .then(...).catch(()=>{})
--        El catch vacio se traga el error. El cron reportaba exito 576
--        veces seguidas mientras el worker moria en cada intento.
--
-- COMO LO ENCONTRE:
--   Llame a la edge function directo desde Postgres con net.http_post y
--   public.sk(), y lei la respuesta en net._http_response:
--     500 {"ok":false,"error":"canceling statement due to statement timeout"}
--
-- LA CONSULTA CULPABLE, CRONOMETRADA:
--   public.refresh_soccer_crossleague_coverage_jobs(now())  ->  57.12 s
--   Es lo PRIMERO que hace el worker, antes de tocar ningun job.
--   Por dentro, v2.fn_refresh_crossleague_coverage_jobs linea 14:
--     left join lateral v2.fn_crossleague_features_canonical(s.team_espn_id, p_decision_time)
--   Se llama una vez por equipo Y por partido de los proximos 21 dias.
--   Medido: 462 llamadas, ~123 ms cada una.
--
-- LO QUE CONSIDERE Y DESCARTE:
--   Deduplicar equipos antes del lateral. La funcion recibe p_decision_time
--   (constante), no la fecha del partido, asi que el valor es identico para
--   todas las filas del mismo equipo y deduplicar seria EQUIVALENTE.
--   Pero lo medi: 462 llamadas contra 420 necesarias, factor 1.10.
--   Ahorra 9%: 57s -> ~52s. Sigue reventando. No resuelve nada, asi que
--   no toque la logica.
--
-- EL ARREGLO: darle a esas funciones su propio statement_timeout.
--   No cambia UNA SOLA LINEA de su logica. Solo dejan de morir a la mitad.
--   180s da margen sobre los 57s medidos.
-- =====================================================================

alter function public.refresh_soccer_crossleague_coverage_jobs(timestamptz)
  set statement_timeout = '180s';
alter function v2.fn_refresh_crossleague_coverage_jobs(timestamptz)
  set statement_timeout = '180s';
alter function public.refresh_soccer_phi_history_jobs(text)
  set statement_timeout = '180s';
alter function v2.fn_refresh_phi_history_jobs(text)
  set statement_timeout = '180s';

-- ---------------------------------------------------------------------
-- VERIFICACION EJECUTADA (no es teoria, es la respuesta real):
--
--   select net.http_post(
--     url := '.../functions/v1/soccer-global-backfill',
--     headers := jsonb_build_object('Authorization','Bearer '||public.sk(),
--                                   'Content-Type','application/json'),
--     body := '{"limit":3}'::jsonb, timeout_milliseconds := 180000);
--
--   ANTES:  500 {"ok":false,"error":"canceling statement due to statement timeout"}
--   DESPUES: 200 {"ok":true,"processed":3,"results":[
--     {"team":"Hull City",     "league":{"id":40,"name":"EFL Championship"},
--      "observations":26,"writes":26,"status":"DATA_READY"},
--     {"team":"Ipswich Town",  "league":{"id":40,"name":"EFL Championship"},
--      "observations":26,"writes":26,"status":"DATA_READY"},
--     {"team":"Coventry City", "league":{"id":40,"name":"EFL Championship"},
--      "observations":31,"writes":31,"status":"DATA_READY"}]}
--
--   Coventry City es uno de los partidos que reporto el dueno.
--
--   v2.soccer_domestic_observation: 2810 -> 2893 filas (+83 partidos reales)
--                                     33 -> 36 equipos
--                                     14 -> 15 ligas
--
--   El cron 420 corre cada 5 minutos con limit 6, asi que la cola de ~120
--   equipos se vacia sola en unas horas. No hay que empujarla a mano.
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- LO QUE QUEDA ABIERTO Y NO ES MIO TAPARLO:
--
-- 1. El catch vacio de soccer-global-backfill-kick sigue ahi:
--       .then(async r=>{try{await r.text()}catch{}}).catch(()=>{})
--    Mientras siga asi, CUALQUIER falla futura del worker volvera a ser
--    invisible y el cron seguira reportando exito. El arreglo de verdad es
--    que el kick registre el status de la respuesta en una tabla. Eso es
--    editar la edge function y lo dejo propuesto, no hecho.
--
-- 2. refresh_soccer_crossleague_coverage_jobs sigue tardando 57s y corre en
--    CADA invocacion, cada 5 minutos. Funciona, pero es caro. Bajarlo
--    requiere optimizar fn_crossleague_features_canonical o refrescar la
--    cola cada 30 min en vez de cada 5. Lo segundo es editar la edge
--    function; lo primero es tocar el motor de features. Ninguno es un
--    parche de una linea y ninguno es urgente ahora que ya no muere.
-- ---------------------------------------------------------------------
