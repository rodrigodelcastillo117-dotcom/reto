-- iss069 · RONGOL: por qué fallaba TODOS los días y por qué mi primer arreglo
--          estaba equivocado.
--
-- HISTORIAL DEL FALLO (cron.job_run_details, job 182)
--   Con `CALL rongol_ciclo_seguro()`:  "invalid transaction termination" en el COMMIT
--                                      de la línea 7. Falla SIEMPRE.
--   Con `select rongol_ciclo()`:       "server restarted". Falla SIEMPRE.
--   Antes, intermitente:               "canceling statement due to statement timeout"
--                                      dentro de prior_del_equipo, vía
--                                      agente_analizar_futuros(72,400). 127.7s.
--
-- MI PRIMER ARREGLO ESTABA MAL. Repunté el job de rongol_ciclo_seguro() (que tiene
-- 17 COMMIT) a rongol_ciclo() (que no tiene ninguno). El error de COMMIT desapareció
-- y apareció "server restarted" dos veces seguidas. Cambié un error por otro.
-- El COMMIT no era el problema: era el síntoma de que alguien ya se había dado cuenta
-- de que el ciclo es demasiado pesado para una sola transacción.
--
-- POR QUÉ NINGUNA DE LAS DOS PUEDE FUNCIONAR
-- rongol_ciclo_seguro YA es un PROCEDURE (pg_proc.prokind='p'), así que el COMMIT es
-- legal en PL/pgSQL. Lo que no es legal es hacer COMMIT dentro del comando que ejecuta
-- pg_cron, porque pg_cron corre cada job dentro de una transacción. Así que ni la
-- versión con COMMIT ni la versión sin COMMIT sirven: hay que partir el trabajo en
-- JOBS SEPARADOS, y ahí pg_cron ya le da una transacción propia a cada uno. El COMMIT
-- deja de hacer falta.
--
-- MEDICIÓN, PASO POR PASO (lo que nadie había hecho)
-- Creé rongol_paso(texto) para ejecutar y cronometrar cada etapa por separado:
--   ingerir_apuestas 0.41s · ingerir_oraculo 0.07s (91 memorias nuevas)
--   ingerir_nfl 0.03s · auditar 0.03s · aprender 1.98s · dixon_coles 0.10s
--   calibracion 0.06s · zonas 0.04s · calidad_ligas 0.05s · ratings 4.05s
--   nfl_predecir 0.70s · corners_tarjetas 0.04s · enlazar 0.08s
--   ---------------------------------------------------------------
--   LOS 13 PASOS JUNTOS: 7.64 SEGUNDOS.
-- Es decir: el ciclo "pesado" no era pesado. Los culpables eran DOS, los dos
-- escondidos:
--   (a) agente_analizar_futuros(72, 400): 545 candidatos en la ventana de 72h.
--       89 con datos = 54.3s medidos (0.61s c/u, peor caso 1.39s). Los otros ~456
--       NO tienen muestra, nunca guardan fila en fut_predicciones, y por eso se
--       reintentaban COMPLETOS en cada corrida: 16s de puro desperdicio.
--   (b) el INSERT de bitácora, que hace `count(*) from picks_premium`. picks_premium
--       es una VISTA que no se podía ni contar en 25s (ver iss068).
--   Total: ~78 segundos en UNA transacción, seis veces al día.
--
-- ARREGLO (tres piezas)
-- 1) agente_analizar_futuros_lote(horas, limite, frescura_min, reintento_sin_muestra_h)
--    Misma matemática, cuatro cambios de ingeniería:
--      - ordena por generado_at ASC NULLS FIRST => cada corrida AVANZA, no repite
--        los mismos 400 de siempre (la original hacía UPSERT sobre todos).
--      - salta los analizados hace menos de `frescura_min` => trabajo acotado.
--      - tabla fut_sin_muestra: marca los que no dan muestra y los reintenta solo
--        cada 12h => deja de quemar 16s por corrida en ~456 partidos estériles.
--      - cada partido en su propio bloque EXCEPTION con statement_timeout de 8s =>
--        un partido lento se registra en rongol_paso_log y el lote sigue. Antes,
--        uno solo tumbaba la corrida completa.
--    Estado medido tras drenar la ventana: 0 pendientes en 0.04s. Con 40 rancios: ~27s.
-- 2) rongol_paso(paso, timeout_ms): ejecuta UNA etapa, la cronometra y la registra en
--    rongol_paso_log (ok/segundos/detalle), con EXCEPTION para que un fallo quede
--    escrito en lugar de perderse. Esto es lo que faltaba para poder diagnosticar.
-- 3) Un cron job por etapa (pg_cron le da transacción propia a cada uno):
--      182 rongol-ciclo           02:15  ingestas + aprender
--      456 rongol-etapa2-recalculos 02:20  dixon_coles, calibracion, zonas,
--                                          calidad_ligas, corners_tarjetas
--      457 rongol-etapa3-ratings  02:25  ratings, enlazar
--      458 rongol-etapa4-futuros  02:30  futuros (lote acotado)
--      459 rongol-etapa5-cierre   02:40  nfl_predecir, bitacora
--    Y los jobs 179 (5 veces/día) y 239 (1 vez/día), que llamaban el mismo monolito
--    de 400, repuntados al lote. El job 423 (recuperación de un solo uso) eliminado.
--
-- LA BITÁCORA YA NO CUENTA picks_premium. En su lugar registra señales baratas y más
-- útiles: fut_predicciones frescas (6h), sin_muestra marcados, pasos ok/fallidos en 24h.
--
-- NOTA HONESTA: `rongol_memoria` dejó de crecer el 2026-09-06, exactamente cuando el
-- cron empezó a fallar. Era un solo problema, no dos. La ingesta ya volvió a correr
-- (91 memorias nuevas en la primera ejecución manual de ingerir_oraculo).

create table if not exists public.rongol_paso_log (
  id bigserial primary key,
  paso text not null,
  inicio timestamptz not null default now(),
  fin timestamptz,
  ok boolean,
  segundos numeric,
  detalle text
);
create index if not exists rongol_paso_log_paso_idx on public.rongol_paso_log (paso, inicio desc);

create table if not exists public.fut_sin_muestra (
  fixture_id bigint primary key,
  intentado_at timestamptz not null default now(),
  intentos int not null default 1,
  motivo text
);
comment on table public.fut_sin_muestra is
 'Partidos sin muestra suficiente para lambdas/mercados. Evita reintentar los mismos ~456 partidos en cada corrida. Se reintentan cada 12h por si llega data nueva.';

-- agente_analizar_futuros_lote() y rongol_paso() se aplicaron con el cuerpo completo
-- vía execute_sql (apply_migration hace rollback silencioso en este proyecto).
-- El cuerpo vigente se puede recuperar con:
--   select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--   where n.nspname='public' and p.proname in ('agente_analizar_futuros_lote','rongol_paso');

-- Cron aplicado:
-- select cron.alter_job(179, command => 'select public.agente_analizar_futuros_lote(72, 60, 120, 12);');
-- select cron.alter_job(239, command => 'select public.agente_analizar_futuros_lote(72, 60, 120, 12);');
-- select cron.alter_job(182, command => 'select public.rongol_paso(''ingerir_apuestas'',60000), ...');
-- select cron.unschedule(423);
-- select cron.schedule('rongol-etapa2-recalculos', '20 2 * * *', '...');  -- 456
-- select cron.schedule('rongol-etapa3-ratings',    '25 2 * * *', '...');  -- 457
-- select cron.schedule('rongol-etapa4-futuros',    '30 2 * * *', '...');  -- 458
-- select cron.schedule('rongol-etapa5-cierre',     '40 2 * * *', '...');  -- 459

-- CÓMO SE VERIFICA MAÑANA (02:15-02:40 UTC):
--   select paso, ok, segundos, detalle from public.rongol_paso_log
--   where inicio > now() - interval '1 day' order by id;
--   select jobid, status, return_message from cron.job_run_details
--   where jobid in (182,456,457,458,459) and start_time > now() - interval '1 day';
