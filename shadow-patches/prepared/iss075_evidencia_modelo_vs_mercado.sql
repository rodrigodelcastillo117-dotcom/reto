-- iss075 · POR QUÉ EL CEREBRO NUNCA DA UN PICK. La cadena completa, y el arreglo.
--
-- El owner preguntó por qué `es_pick` está en 0 en los tres deportes. Seguí la cadena
-- hasta el fondo. No es un bug suelto: es un circuito abierto de cinco eslabones.
--
-- ===== LA CADENA =====
-- 1. v_pick_canonico llama a economic_eligibility_v1, que tiene NUEVE compuertas y
--    todas deben pasar para marcar es_pick.
-- 2. La vista le pasaba 'model_version', NULL::text y 'model_skill', NULL::text
--    HARDCODEADOS. Así que la PRIMERA compuerta fallaba siempre.
-- 3. Resultado: es_pick_reason = 'MODEL_VERSION_PROVENANCE_MISSING' en el 100% de las
--    filas, en los tres deportes (323 de 323 medidas el 2026-09-11). Eso ESCONDÍA el
--    estado real: parecía un dato faltante cuando la procedencia SÍ existe.
-- 4. La segunda compuerta consulta economic_model_authority, que está VACÍA: cero
--    filas. Ningún modelo está autorizado para decidir con dinero.
-- 5. La tercera exige model_skill = 'SKILL_PASS', que nadie puede afirmar sin comparar
--    el modelo contra el mercado sobre partidos ya jugados. Y esa comparación NO SE
--    ESTABA GUARDANDO EN NINGÚN LADO:
--      - pick_learning_data: 547 filas, ai_predicted_prob en NULL en LAS 547.
--        Guarda la probabilidad del mercado y el resultado, nunca la del modelo.
--      - mlb_shadow_predicciones: 800 filas con Brier, pero TODAS del mismo instante
--        (backfill del 5-sep 07:43) y sin ningún cron que la alimente. Congelada.
--      - modelo_backtest: 30,876 filas, pero sin columna de probabilidad de mercado.
--    Sin ese dato, economic_model_authority NO SE PUEDE LLENAR NUNCA de forma honesta,
--    y por lo tanto es_pick sería false PARA SIEMPRE. El circuito estaba abierto.
--
-- ===== LO QUE NO HICE, Y POR QUÉ =====
-- NO llené economic_model_authority. Habría encendido los picks al instante, y habría
-- sido exactamente lo que el owner prohibió ("nada de P_RETO falso", "nunca sustituyas
-- P_RETO con el implied/no-vig de la casa"). La evidencia que SÍ existe dice que no se
-- debe autorizar:
--   MLB  : mlb_shadow_predicciones, n=800 liquidadas.
--          Brier prod_espejo_0.5 = 0.24707 · shadow_0.2 = 0.24801.
--          Un volado es 0.25 y "siempre el local" (tasa 0.538) es ~0.2486.
--          El modelo de MLB NO TIENE HABILIDAD MEDIBLE. Y predecir_mlb lo dice solo en
--          su aviso_modelo: "En beisbol el mercado casi siempre tiene razon... No
--          apostar la linea de ganador". Tiene razón.
--   NFL  : Brier del modelo 0.22702 vs mercado 0.21822 sobre 208 partidos de UNA
--          temporada, t pareada -1.135. EL MERCADO GANA. Falla el criterio de
--          reingreso por los dos lados (n<250, 1 temporada; y no le gana al no-vig).
--   FÚTBOL: calibración confiable en 131 de 142 filas y muestra >=20 en 134, pero
--          CERO comparación contra el mercado guardada. NO SE PUEDE JUZGAR. Que no
--          haya evidencia en contra no es evidencia a favor.
--
-- ===== LO QUE SÍ HICE =====
-- (a) `modelo_version_activa(deporte)`: devuelve la procedencia REAL.
--     futbol -> get_active_crossleague_model_version() = 'crossleague_v1'
--     NFL    -> nfl_reto_modelo = 'nfl-2026.09.2'  (verificado: 31 partidos, y sus
--               probabilidades DISCREPAN del mercado -- BUF@HOU: mercado 48.3,
--               modelo 61.2 -- asi que es un modelo independiente y no la cuota de la
--               casa sin vig, al contrario de lo que dice la etiqueta nfl_sin_modelo
--               del 5-sep, que quedo obsoleta)
--     MLB    -> NULL, porque genuinamente no hay modelo propio versionado.
--     NO INVENTA VERSIONES: donde no hay, devuelve NULL y la compuerta sigue cerrada.
-- (b) Cableé esa procedencia en v_pick_canonico, y declaré model_skill como
--     'SKILL_UNKNOWN' -- NO 'SKILL_PASS'. La compuerta SIGUE CERRADA a proposito.
--     Lo unico que cambia es que el motivo dejo de mentir:
--       baseball -> MODEL_VERSION_PROVENANCE_MISSING  (cierto: no hay modelo)
--       football -> ECONOMIC_MODEL_UNAUTHORIZED       (cierto: hay modelo, sin permiso)
--       soccer   -> ECONOMIC_MODEL_UNAUTHORIZED       (cierto: hay modelo, sin permiso)
--     es_pick sigue en 0 en los tres. Verificado despues del cambio.
-- (c) `evidencia_modelo_forward`: la prueba hacia adelante que faltaba. Guarda, ANTES
--     del saque, la probabilidad del MODELO y la del MERCADO (cruda y sin vig) para el
--     mismo pick, y despues el resultado, el Brier de cada uno y el marcador.
--     `CHECK (decision_time < kickoff)` hace FISICAMENTE IMPOSIBLE guardar una
--     "prediccion" despues del partido. Probado adversariamente: el intento de meter
--     una prediccion 3 horas posterior al saque fue rechazado, 0 filas guardadas.
-- (d) `evidencia_liquidar()` NO reimplementa la calificacion: reutiliza
--     evaluar_leg_parlay_v1, el mismo calificador con el que se paga el dinero. Y solo
--     cierra con 'ganado'/'perdido'; un 'no_evaluable' se queda pendiente, porque meter
--     un resultado inventado contaminaria justo la evidencia que decide si se apuesta.
-- (e) `v_evidencia_modelo_vs_mercado`: Brier del modelo vs Brier del mercado, la
--     diferencia, la t pareada (con |t| < 2 la diferencia no se distingue del ruido) y
--     `cumple_muestra` (n >= 250). ES LA UNICA FUENTE VALIDA para llenar
--     economic_model_authority.
--
-- Primera captura: 19 predicciones, 18 de futbol y 1 de NFL, todas antes del saque.
-- Discrepancia media modelo vs mercado sin vig: futbol 8.0 puntos, NFL 10.4.
-- Crons: 462 evidencia-capturar (cada 2h), 463 evidencia-liquidar (cada hora).
--
-- ===== COMO SE ENCIENDEN LOS PICKS, CUANDO SE LO GANEN =====
-- Cuando v_evidencia_modelo_vs_mercado muestre, para un deporte,
-- diferencia_a_favor_del_modelo > 0 con t_pareada > 2 y cumple_muestra = true,
-- ENTONCES y solo entonces:
--   insert into public.economic_model_authority
--     (deporte, mercado, fuente, model_version, economic_authorized)
--   values (...);
-- Es una decision del owner, con dinero de por medio, y con la evidencia enfrente.
-- Yo no la tomo.

create table if not exists public.evidencia_modelo_forward (
  id bigserial primary key,
  espn_event_id text not null,
  deporte text not null,
  liga text, partido text, home text, away text,
  mercado text not null,
  pick_desc text not null,
  model_version text,
  prob_modelo numeric not null,
  prob_mercado_cruda numeric,
  prob_mercado_novig numeric,
  momio_mercado numeric,
  casa text,
  decision_time timestamptz not null default now(),
  kickoff timestamptz not null,
  resultado text, acerto boolean,
  brier_modelo numeric, brier_mercado numeric,
  marcador text, cerrado_at timestamptz,
  constraint evidencia_antes_del_saque check (decision_time < kickoff),
  constraint evidencia_unica unique (espn_event_id, mercado, pick_desc, model_version)
);
create index if not exists evidencia_pendiente_idx
  on public.evidencia_modelo_forward (kickoff) where acerto is null;
create index if not exists evidencia_deporte_idx
  on public.evidencia_modelo_forward (deporte, model_version, cerrado_at);

-- Los cuerpos vigentes de modelo_version_activa, evidencia_capturar,
-- evidencia_liquidar y v_evidencia_modelo_vs_mercado se recuperan con:
--   select prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
--   where n.nspname='public' and p.proname in
--     ('modelo_version_activa','evidencia_capturar','evidencia_liquidar');
--   select pg_get_viewdef('public.v_evidencia_modelo_vs_mercado'::regclass, true);
--
-- El recableado de v_pick_canonico se hizo con cirugia de texto sobre
-- pg_get_viewdef EXIGIENDO que el ancla apareciera exactamente 1 vez:
--   ANTES:  'model_version', NULL::text, 'model_skill', NULL::text,
--   AHORA:  'model_version', public.modelo_version_activa(c.deporte),
--           'model_skill', 'SKILL_UNKNOWN'::text,
