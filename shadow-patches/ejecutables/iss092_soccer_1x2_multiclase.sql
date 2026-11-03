-- iss092 — SOCCER 1X2 MULTICLASE
--
-- Pedido del dueño: hacerlo EN PARALELO, sin detener lo demás. Aquí está.
-- SIN EV. SIN KELLY. SIN EDGE CONTRA EL MERCADO. La tabla futbol_5ligas_2526
-- tiene columnas `cuota_cierre_*`; NINGUNA se usa aquí. Las lambdas salen de
-- goles anotados y recibidos, y nada más.
--
-- ===========================================================================
-- UNIVERSO
-- ===========================================================================
-- 32,528 partidos de `historico_partidos_espn` en 57 competencias
-- (2023-07-01 a 2026-09-11), EXCLUYENDO `soccer/club.friendly`: los amistosos
-- de club son el análogo futbolero de la pretemporada y no pintan nada en un
-- backtest. Tras exigir historia suficiente quedan **19,339 partidos en 41
-- competencias**.
--
-- Tasas base medidas: Local 44.28% · Empate 24.40% · Visita 31.32%.
-- OJO CON ESTO: el empate está POR DEBAJO del 33.3% de `base_azar`. Con la
-- regla de `ventaja_sobre_azar` del dueño, un pick de EMPATE casi nunca podrá
-- superar el azar en un 1X2. No es un defecto del modelo; es aritmética del
-- mercado de 3 vías, y hay que decirlo antes de que alguien pregunte por qué
-- nunca sale un empate.
--
-- ¿Son Poisson los goles? MEDIDO, no supuesto: var/media = 1.1326 sobre 65,056
-- observaciones equipo-partido. Sobredispersión leve. Muy distinto de los
-- totales de MLB/NFL, donde la sd real era ~2x la de Poisson y hubo que pasarse
-- a una Normal con sigma medida. Para goles de futbol, Poisson aguanta.
--
-- ===========================================================================
-- EL BUG QUE CASI SE FUE A PRODUCCIÓN (y cómo se cazó)
-- ===========================================================================
-- Primera versión: la fuerza del equipo se medía con su tasa POOLED (local +
-- visitante) y se comparaba contra una línea base ESPECÍFICA DE SEDE. Peras con
-- manzanas. Resultado: lam_home 1.3285 / lam_away 1.5316 contra una realidad de
-- 1.5462 / 1.2392 — LA VENTAJA LOCAL SALIÓ INVERTIDA.
-- Se cazó porque la comprobación compara el promedio predicho contra el
-- promedio real ANTES de reportar nada.
-- Arreglo: la fuerza se mide contra una base NEUTRAL DE SEDE ((bh+ba)/2) y la
-- ventaja local entra SOLO por bh vs ba. Verificado:
--     lam_home 1.5613 vs real 1.5462 · lam_away 1.2639 vs real 1.2392
--     corr(lam_home, goles_local) 0.2763 · corr(lam_away, goles_visita) 0.2426
-- (MLB/NFL en iss089 NO tienen este defecto: ahí la tasa del equipo y la base
--  son ambas específicas de sede, así que son consistentes.)
--
-- ===========================================================================
-- MODELO
-- ===========================================================================
-- Ventana de equipo 18 meses (min 15 partidos), línea base POR COMPETENCIA
-- 90 días (min 50 partidos). La base por competencia es importante: eng.1 y
-- ksa.1 no tienen el mismo nivel de goles ni la misma ventaja local, y así cada
-- liga aporta la suya sin que se presten calibración entre ellas.
-- Encogimiento peso 10. Clamp de lambda [0.20, 4.50].
-- P(H)/P(D)/P(A) por Poisson independiente sobre la rejilla 0..12 goles.
-- Masa truncada máxima: 0.00024116. Se renormaliza y se reporta.
--
-- LINAJE igual que el resto: asof_home, asof_away, asof_league y
-- data_asof_real = greatest(los tres). 0 violaciones, margen mínimo 1.000 día.
--
-- ===========================================================================
-- RESULTADO: EL DÉFICIT DE EMPATES ES REAL Y LA CORRECCIÓN NO SE GANA EL PUESTO
-- ===========================================================================
-- El Poisson independiente subestima los empates. Es el fallo de libro de este
-- modelo y aquí aparece tal cual, en TODOS los periodos medidos:
--     predicho ~0.238-0.243   real 0.244-0.268
--
-- Se probó un escalado vectorial p_c ∝ exp(a_c + b·ln p_c) (a_home = 0 por
-- identificabilidad; 3 parámetros; ajuste por descenso coordenado DETERMINISTA,
-- sin aleatoriedad, para que el replay dé lo mismo siempre).
--
-- Folds internos (aquí se eligió el método):
--   fold 1  entrena <2024-07-01 (4,626)   evalúa 2024-07→2025-07 (7,235)
--       identity        Brier multi 0.620181   logloss 1.032769
--       vector_scaling  Brier multi 0.619913   logloss 1.032685
--       bootstrap: media 0.000258  IC95 [-0.000535, 0.001044]  71.8%  NO
--   fold 2  entrena <2025-07-01 (11,861)  evalúa 2025-07→2026-01 (2,820)
--       identity        Brier multi 0.621452   logloss 1.035167
--       vector_scaling  Brier multi 0.620949   logloss 1.034409
--       bootstrap: media 0.000517  IC95 [-0.000651, 0.001656]  81.2%  NO
--
--   Gana en 2/2 folds pero NO es significativo en ninguno, y los parámetros
--   derivan fuerte: a_draw 0.13 → 0.03 → 0.02, b 1.01 → 0.92 → 0.92. La tasa
--   de empate se mueve sola entre periodos, así que la corrección ajustada en
--   uno se pasa de largo en el siguiente.
--
--   Walk-forward agrupado, 14,713 partidos, params por ventana:
--       Brier multi 0.620185 → 0.619724   media 0.000464
--       IC95 [-0.00004, 0.000993]   95.9% a favor   NO SIGNIFICATIVO
--   Aquí la diferencia con MLB importa: en MLB el agrupado SÍ era significativo
--   y por eso Platt quedó elegido. En soccer falla incluso agrupado. El rechazo
--   aguanta en todos los niveles de agregación, no sólo en el más exigente.
--
-- DECISIÓN: identity. El escalado vectorial queda RECHAZADO.
--
-- ===========================================================================
-- HOLDOUT LIMPIO 2026 (medido UNA vez, método ya fijado)
-- ===========================================================================
--   4,658 partidos, identity:
--       Brier multiclase 0.619422   (uniforme 1/3 = 0.666667)
--       LogLoss          1.031835   (uniforme = 1.098612)
--       acierto argmax   48.15%
--       marginal local 0.4434 vs 0.4418 real   — muy bien
--       marginal empate 0.2414 vs 0.2581 real  — corto por 1.7 pp
--       marginal visita 0.3153 vs 0.3001 real  — largo por 1.5 pp
--   Baseline "siempre local": Brier multiclase 1.116359. El modelo le saca
--   mucho a la heurística boba, y eso es lo mínimo que se le pide.
--
-- CONSTANCIA HONESTA: en el holdout, el método RECHAZADO habría dado
-- Brier 0.618688 y marginal de empate 0.2581 contra 0.2581 real — clavado.
-- NO se adopta por eso. Cambiar de método mirando el holdout es exactamente el
-- pecado que el auditor señaló. Queda escrito, no aplicado.
--
-- OJO: el Brier de aquí es MULTICLASE (suma sobre 3 clases, rango 0..2). NO se
-- compara con el 0.237 binario de MLB. Por eso se marca en `metrica_brier`.
--
-- apto_para_lock = false. SIN LOCK, SIN "Lo Mejor", SIN Parlay, SIN Reto13M.

-- ===========================================================================
-- NOTA DE ESQUEMA: el UNIQUE existente no protegia 1X2
-- ===========================================================================
-- calib_evento_unico es UNIQUE (model_version, mercado, espn_event_id, linea).
-- En 1X2 `linea` es NULL y Postgres trata los NULL como DISTINTOS, asi que la
-- restriccion no impedia duplicar un partido. Indice parcial para cerrarlo:
create unique index if not exists calib_evento_unico_sin_linea
  on public.calib_eventos (model_version, mercado, espn_event_id)
  where linea is null;

alter table public.calibradores
  drop constraint if exists calibradores_metodo_check;
alter table public.calibradores
  add constraint calibradores_metodo_check check (metodo = any (array[
    'identity','platt','isotonic','multiclase_dirichlet','vector_scaling']));

alter table public.calibradores
  add column if not exists metrica_brier text not null default 'binaria';
comment on column public.calibradores.metrica_brier is
  'binaria (rango 0..1, baseline volado 0.25) o multiclase (rango 0..2, baseline uniforme 3 clases 0.666667). No se comparan entre si.';

insert into public.calibradores
 (calibration_version, model_version, deporte, mercado, metodo, params,
  train_desde, train_hasta, test_desde, test_hasta,
  n_train_eventos, n_train_partidos, n_test_eventos, n_test_partidos, n_push,
  brier_raw, brier_cal, logloss_raw, logloss_cal, ece_raw, ece_cal,
  temporal_violations, mejora_oos, elegido, apto_para_lock, metrica_brier, motivo)
values
 ('cal_v4_historia_completa','soccer_1x2_poisson_v1','soccer','1X2','identity',
  '{}'::jsonb, '2000-01-01','2026-01-01','2026-01-01','2027-01-01',
  0, 0, 4658, 4658, 0,
  0.619422, 0.619422, 1.031835, 1.031835, null, null,
  0, false, true, false, 'multiclase',
  'IDENTITY. El escalado vectorial gano en 2/2 folds internos pero NO fue significativo en ninguno (IC95 [-0.000535,0.001044] y [-0.000651,0.001656]) y sus parametros derivan: a_draw 0.13->0.03->0.02. Ni agrupando las 3 ventanas (14,713 partidos) alcanza: IC95 [-0.00004,0.000993], 95.9% a favor. El rechazo aguanta en todos los niveles de agregacion. Holdout limpio 2026: 4,658 partidos, Brier multiclase 0.619422 contra 0.666667 del uniforme, logloss 1.031835 contra 1.098612, acierto argmax 48.15%, baseline siempre-local 1.116359. Deficit de empates conocido y no corregido: 0.2414 predicho vs 0.2581 real. NO APTO PARA LOCK.'),
 ('cal_v4_historia_completa','soccer_1x2_poisson_v1','soccer','1X2','vector_scaling',
  '{"a_draw":0.02,"a_away":-0.07,"b":0.92,"forma":"p_c proporcional a exp(a_c + b*ln p_c), a_home=0"}'::jsonb,
  '2000-01-01','2026-01-01','2026-01-01','2027-01-01',
  14681, 14681, 4658, 4658, 0,
  0.619422, 0.618688, 1.031835, 1.030646, null, null,
  0, false, false, false, 'multiclase',
  'RECHAZADO. Corrige el deficit de empates del Poisson independiente (a_draw>0) y en el holdout habria clavado el marginal de empate (0.2581 vs 0.2581 real) con Brier 0.618688. Aun asi se rechaza: en los folds internos, que son donde se decide, no fue significativo ni una vez, y los parametros derivan entre periodos porque la tasa de empate se mueve sola. Adoptarlo mirando el holdout seria elegir el metodo con el dato reservado para juzgarlo. b=0.92 y no 0.79 como en MLB: este modelo NO esta sobreconfiado, su problema es repartir mal entre empate y visita.');

-- FIN iss092.
