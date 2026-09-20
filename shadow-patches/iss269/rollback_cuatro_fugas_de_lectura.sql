-- ROLLBACK de ISS269: devuelve las 4 politicas de lectura a USING(true).
--
-- OJO A LO QUE ESTO REABRE (medido el 2026-09-20, no estimado):
--   anon volveria a leer 33 filas de user_patterns, 58 de ai_generated_parlays
--   y 71 de parlay_builder_log. En user_patterns eso incluye apodo + win_rate +
--   roi + net_pnl + insight, es decir: cuanto ha perdido cada persona y en que
--   liga, legible por cualquiera con la llave publicable.
--   Un autenticado volveria a ver las 33 filas teniendo solo 11 propias.
--
-- No lo corras "por si acaso". Solo si se demuestra que una pantalla real
-- dependia de leer filas ajenas, que es justo lo que se cerro.

alter policy user_patterns_select_all on public.user_patterns
  using (true);

alter policy ai_generated_parlays_select on public.ai_generated_parlays
  using (true);

alter policy parlay_builder_log_select on public.parlay_builder_log
  using (true);

alter policy fantasy_start_sit_lectura on public.fantasy_start_sit
  using (true);
