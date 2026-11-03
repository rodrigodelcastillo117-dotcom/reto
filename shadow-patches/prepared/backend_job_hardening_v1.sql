-- ✅ APLICADO A PROD 2026-10-14 — endurecimiento de jobs que fallaban por statement_timeout.
-- Hallazgo (chequeo de salud, últimas 24h): la mayoría de "fallas" fueron un único blip
-- transitorio a las 16:41 (reinicio de servidor, 1 falla entre cientos de corridas = ruido).
-- Dos jobs sí fallaban de forma recurrente por timeout en consultas/vistas pesadas:
--
-- 1) job 515 reto-global-candidate-snapshot-v1 (cada 15 min): refresh del matview
--    mv_reto13m_global_candidate_v2 (el matview pesa 120 kB; lo caro es COMPUTAR la
--    consulta fuente). 13/95 fallas, 8 seguidas en una ventana de carga. → Global se
--    estancaba a ratos. Fix: set statement_timeout a 300s en el comando del cron,
--    manteniendo REFRESH ... CONCURRENTLY (no bloquea lecturas).
--
-- 2) job 366 motor-cache-horizonte-largo (diario 09:25): select refrescar_motor_cache(240,20)
--    hacía timeout dentro de la función consultando v_futpro_publication_v3. Fix:
--    set statement_timeout a 600s en el comando del cron.
--
-- Aplicado vía cron.alter_job. No cambia frecuencia ni lógica; solo da tiempo suficiente.

select cron.alter_job(
  515,
  command := 'set statement_timeout to ''300s''; refresh materialized view concurrently public.mv_reto13m_global_candidate_v2;'
);

select cron.alter_job(
  (select jobid from cron.job where jobname = 'motor-cache-horizonte-largo'),  -- job 366
  command := 'set statement_timeout to ''600s''; select public.refrescar_motor_cache(240, 20);'
);

-- Pendiente (más profundo, no urgente): optimizar la consulta fuente de
-- mv_reto13m_global_candidate_v2 (índices / reescritura) para que el refresh sea
-- rápido por sí mismo, en vez de depender del timeout ampliado.
