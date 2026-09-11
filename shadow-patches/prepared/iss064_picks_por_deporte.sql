-- iss064 — Parlay del Día, Reto 13M y Picks con Valor: picks reales, por deporte.
--
-- 1. `public.parlay_del_dia_v3(p_ventana_horas)` — los tres bloques que pidió el owner:
--      bloque 1 · LOS 3 MEJORES     → uno por deporte, el de mayor desacuerdo con el mercado
--      bloque 2 · MÁS ARRIESGADO    → hasta 5; si un deporte trae varios tipo LOCK, entran varios
--      bloque 3 · LOS 6             → 2 por deporte, parejo
--    Antes daba 3 de fútbol siempre. Sale de `v_mejor_pick_por_partido`, que ordena por
--    DISCRIMINACIÓN (nuestra probabilidad − la que implica el precio), no por probabilidad cruda.
--
--    VENTANA POR DEPORTE: NFL usa 8 días porque juega una vez por semana. Con 48 h fijas el
--    único partido de NFL (a 61 h) se caía y volvíamos a un parlay de puro fútbol y béisbol,
--    que es justo lo que se quería arreglar. Ya me había mordido este mismo problema en la
--    matriz canónica; aquí lo evité antes de que pasara.
--
--    MEDIDO — bloque 1, tres deportes, tres mercados distintos:
--      béisbol · ML Miami Marlins .... nosotros 46.3 % · casa 37.0 % · +9.3 pp
--      fútbol  · Gana LAFC ........... nosotros 69.5 % · casa 60.8 % · +8.7 pp
--      NFL     · Over 43.5 (KC-DEN) .. nosotros 61.7 % · casa 53.5 % · +8.2 pp
--
-- 2. `public.v_reto13m_mejores` — lo mejor de cada deporte. `rn_deporte = 1` es el mejor de su
--    deporte, `es_lock` marca desacuerdo >= 5 pp. Piso de 3 pp: sin desacuerdo real no es un
--    "mejor pick", es relleno.
--
-- 3. `public.v_picks_con_valor` — la ÚNICA superficie con EV, por decisión del owner. Exige EV
--    positivo **y** probabilidad >= 45 %: un EV alto con probabilidad baja es una lotería.
--
-- ═══ EL HALLAZGO GORDO DE ESTE PASO ═══
-- Al probar las vistas **como `anon`** (que es como las ve la app, no como admin) salió una
-- cadena de permisos rota que hacía que `v_pick_canonico` —el corazón de los picks— tronara
-- entera para el cliente:
--     permission denied for function predecir_mlb
--     permission denied for table    historico_partidos_espn   (vía momio_real_de_mercado)
--     permission denied for table    historico_partidos_espn   (vía ajuste_h2h_over25)
--     permission denied for function economic_model_authorized
--
-- Probar como admin lo ocultaba por completo. Es la misma clase de bug que dejó el análisis de
-- NFL vacío.
--
-- DECISIÓN sobre cómo arreglarlo: había 23 funciones que leen `historico_partidos_espn`.
-- Volverlas todas SECURITY DEFINER habría abierto 14 vectores de escalación, porque varias
-- ESCRIBEN (`reconstruir_nfl_h2h`, `completar_metadatos_live`, `mlb_shadow_generar`).
-- Se optó por un solo GRANT SELECT sobre la tabla, que contiene
-- `espn_event_id, fecha, equipos, marcadores` — CERO datos de usuario, la misma naturaleza
-- que `live_scores` y `nfl_partidos`, que anon ya leía.
--
-- TRAMPA DE EJECUCIÓN, anotada para no repetirla: el primer GRANT se perdió porque iba en la
-- misma llamada que la prueba, y la prueba falló y arrastró la transacción entera. Los GRANT
-- van solos.

grant select on public.historico_partidos_espn to anon, authenticated;
grant execute on function public.predecir_mlb(text) to anon, authenticated;
grant execute on function public.economic_model_authorized(text,text,text,text) to anon, authenticated;
alter function public.momio_real_de_mercado(text,text,text,text,text) security definer;
grant execute on function public.momio_real_de_mercado(text,text,text,text,text) to anon, authenticated;

-- MEDIDO DESPUÉS, con `set local role anon`:
--   v_mejor_pick_por_partido .... 30 filas
--   v_reto13m_mejores ........... 14 filas
--   v_picks_con_valor ........... 15 filas
-- Antes de los GRANT: las tres tronaban con "permission denied".
