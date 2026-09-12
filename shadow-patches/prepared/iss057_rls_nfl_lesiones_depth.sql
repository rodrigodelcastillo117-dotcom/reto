-- iss057 — El análisis de NFL salía incompleto: dos tablas eran invisibles para `anon`.
--
-- SÍNTOMA: el owner reportó "el análisis sigue sin llegar". El dossier abría pero venía
-- vacío de lo que más pesa: lesiones y depth chart.
--
-- CAUSA RAÍZ: las políticas de SELECT de `nfl_lesiones_semana` y `nfl_depth_chart` estaban
-- declaradas `TO authenticated` únicamente. TODAS las demás tablas del dossier de NFL
-- (nfl_partidos, nfl_odds_snapshots, nfl_h2h, nfl_estadios, nfl_clima_hora, nfl_fpi_historico)
-- sí incluyen `anon`. O sea: no era una decisión de privacidad, era una omisión — esas dos
-- tablas quedaron fuera del patrón.
--
-- MEDIDO ANTES: 2,014 filas de lesiones de la semana 1 de 2026 y 247 del depth chart existían
-- en la base y el cliente las leía en CERO. El hook no truena con eso: `Promise.all` recibe
-- `{data: []}` sin error, así que el modal se pintaba sin lesiones y sin profundidad, en
-- silencio. Ese silencio es lo que lo hacía difícil de ver.
--
-- Es el reporte público de lesiones de la NFL, la misma naturaleza que el resto del dossier.
-- No se abre nada que no estuviera ya abierto en las tablas hermanas.

drop policy if exists nfl_lesiones_semana_lectura on public.nfl_lesiones_semana;
create policy nfl_lesiones_semana_lectura on public.nfl_lesiones_semana
  for select to anon, authenticated using (true);

drop policy if exists nfl_depth_chart_lectura on public.nfl_depth_chart;
create policy nfl_depth_chart_lectura on public.nfl_depth_chart
  for select to anon, authenticated using (true);

-- MEDIDO DESPUÉS, con `set local role anon`, sobre los 16 partidos de la semana vigente:
--   16/16 con lesiones (mínimo 112 por partido)
--   16/16 con depth chart (mínimo 13)
--   16/16 con historial de línea y con FPI
--   15/16 con `reto_predice` (el que falta es NE @ SEA, que ya arrancó: el contrato prohíbe
--         por diseño sellar un snapshot después del kickoff)
