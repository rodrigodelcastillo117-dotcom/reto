-- iss091 — DECISIÓN DE CALIBRACIÓN V4 SOBRE LA HISTORIA COMPLETA
--
-- Dos cosas distintas que antes se confundían, y que aquí se separan con una
-- columna propia:
--   elegido        = es el mejor calibrador medido para ese mercado.
--   apto_para_lock = pasó la barra del dueño en el holdout limpio.
-- Un calibrador puede ser el mejor que tenemos y AUN ASÍ no habilitar un LOCK.
-- Esa es exactamente la situación de MLB hoy.
--
-- ===========================================================================
-- LO QUE CAMBIÓ RESPECTO A V3, Y POR QUÉ
-- ===========================================================================
-- V3 concluyó «MLB -> identity, Platt no significativo». Ese número salió de
-- 5,266 partidos porque MLB 2025 tenía 119 juegos de ~2,430 y 2024 tenía 1,796
-- de 2,430. iss088 recuperó la historia (2023: 2,431 / 2024: 2,426 /
-- 2025: 2,429 / 2026: 2,187 al 10-sep). Ahora son 8,657 partidos con lambda.
-- Con la historia completa, la conclusión de MLB SE INVIERTE.
--
-- ===========================================================================
-- MLB Over/Under — FOLDS INTERNOS (aquí se eligió el método)
-- ===========================================================================
--  fold 1  entrena <2024-01-01 (1,645 partidos)  evalúa 2024 (2,371 partidos)
--     identity   Brier 0.246631   ECE 0.093317
--     platt      Brier 0.241134   ECE 0.060071   IC95 [ 0.004248, 0.006718] SÍ
--     isotónica  Brier 0.241460   ECE 0.060004   IC95 [ 0.003957, 0.006450] SÍ
--  fold 2  entrena <2025-01-01 (4,016 partidos)  evalúa 2025 (2,356 partidos)
--     identity   Brier 0.242237   ECE 0.052778
--     platt      Brier 0.238906   ECE 0.011716   IC95 [ 0.001098, 0.005939] SÍ
--     isotónica  Brier 0.239263   ECE 0.012502   IC95 [ 0.000809, 0.005337] SÍ
--
--  Platt le gana a identidad en 2 de 2 folds, significativo en los dos.
--  Platt le gana a la isotónica en 2 de 2. La isotónica NO se adopta: no por
--  prejuicio, sino porque perdió donde se la midió. Era la condición del dueño.
--
-- ===========================================================================
-- MLB Over/Under — HOLDOUT LIMPIO 2026 (medido UNA vez, método ya fijado)
-- ===========================================================================
--     2,075 partidos / 15,870 eventos / 730 pushes
--     Brier RAW 0.239267 -> CAL 0.237714
--     ECE   RAW 0.041366 -> CAL 0.018106   (menos de la mitad)
--     bootstrap por partido: media 0.001745
--     IC95 [-0.000608, 0.004084]  ->  CRUZA CERO. 93% de remuestreos a favor.
--
--   NO PASA la barra del dueño. Lo digo sin adornos: en el holdout limpio,
--   de una sola temporada, la mejora de Brier no es estadísticamente
--   distinguible de cero.
--
-- ===========================================================================
-- EL DATO QUE NO HAY QUE ESCONDER NI SOBREVENDER
-- ===========================================================================
-- Walk-forward agrupado 2024+2025+2026, cada ventana calibrada SÓLO con lo
-- anterior a ella, 6,802 partidos:
--     Brier 0.241258 -> 0.237640   media 0.003639
--     IC95 [0.002536, 0.004759]    100% de remuestreos a favor   SIGNIFICATIVO
-- Y la pendiente de Platt es <1 en TODOS los ajustes: b = 0.857, 0.814, 0.792.
-- La sobreconfianza del modelo es real, estable y va siempre en la misma
-- dirección; las 3 temporadas fuera de muestra mejoran con Platt.
--
-- PERO ese agrupado NO es un holdout limpio: 2 de sus 3 temporadas son las que
-- eligieron el método. No se puede usar para promover. Sirve para una sola
-- cosa: decir que el IC que cruza cero en 2026 huele a falta de potencia
-- (2,075 partidos) y no a ausencia de efecto. No es prueba. Es una sospecha
-- bien medida.
--
-- CONSECUENCIA: platt es elegido=true (es el mejor calibrador medido, gana en
-- las 3 temporadas fuera de muestra y baja el ECE en todas), y
-- apto_para_lock=false (el holdout limpio no alcanzó). Por lo tanto MLB
-- Over/Under puede mostrar ANÁLISIS EXPERIMENTAL y nada más:
-- SIN LOCK, SIN "Lo Mejor", SIN Parlay, SIN Reto13M.
--
-- ===========================================================================
-- NFL Over/Under — sin cambio de conclusión
-- ===========================================================================
--  fold 1  evalúa temporada 2023 (239 partidos)
--     identity 0.238266 (ECE 0.104550)   platt 0.227650 (ECE 0.021416)  gana platt
--  fold 2  evalúa temporada 2024 (239 partidos)
--     identity 0.232611 (ECE 0.072559)   platt 0.257187 (ECE 0.171028)  PIERDE platt
--  1-1, y la derrota es MAYOR que la victoria. Los parámetros de Platt casi no
--  cambian entre folds (a -0.498/-0.455, b 0.874/0.869): lo que cambia es la
--  temporada. Un calibrador que ayuda un año y hace daño el siguiente no se
--  adopta. NFL se queda en identidad.
--  HOLDOUT temporada 2025 con identidad: 238 partidos, Brier 0.226115,
--  ECE 0.045459. 238 partidos sirven para auditar, no para promover.
--
-- SIN EV. SIN KELLY. SIN EDGE CONTRA EL MERCADO. Ninguna decisión de aquí leyó
-- una casa de apuestas.

alter table public.calibradores add column if not exists apto_para_lock boolean not null default false;
comment on column public.calibradores.apto_para_lock is
  'true SOLO si el metodo paso la barra del dueno en el holdout limpio. elegido=true NO implica apto_para_lock=true.';

-- invalidar V3, que se calculó sobre la historia incompleta
update public.calibradores
   set elegido = false, invalidado = true, apto_para_lock = false,
       motivo_invalidacion = 'INVALIDADO por iss091. Se ajusto y evaluo sobre una historia de MLB incompleta: 2025 tenia 119 juegos regulares de ~2,430 y 2024 tenia 1,796. iss088 recuperó el faltante y la conclusion de MLB se invierte. Sustituido por cal_v4_historia_completa.'
 where calibration_version = 'cal_v3_ventanas_correctas';

insert into public.calibradores
 (calibration_version, model_version, deporte, mercado, metodo, params,
  train_desde, train_hasta, test_desde, test_hasta,
  n_train_eventos, n_train_partidos, n_test_eventos, n_test_partidos, n_push,
  brier_raw, brier_cal, logloss_raw, logloss_cal, ece_raw, ece_cal,
  temporal_violations, mejora_oos, elegido, apto_para_lock, motivo)
values
 ('cal_v4_historia_completa','mlb_totales_normal_v1','baseball','Over/Under','platt',
  '{"a":-0.23575247,"b":0.7916973,"convergio":true}'::jsonb,
  '2000-01-01','2026-01-01','2026-01-01','2027-01-01',
  48752, 6372, 15870, 2075, 730,
  0.239267, 0.237714, 0.671449, 0.668163, 0.041366, 0.018106,
  0, true, true, false,
  'ELEGIDO como mejor calibrador: gana a identidad en 2/2 folds internos (significativo en ambos) y a la isotonica en 2/2. Baja el ECE en las 3 temporadas fuera de muestra (0.093->0.060, 0.053->0.012, 0.041->0.018) y la pendiente b<1 es estable (0.857/0.814/0.792). NO APTO PARA LOCK: en el holdout limpio 2026 el IC95 de la mejora de Brier es [-0.000608, 0.004084] y cruza cero (93% de remuestreos a favor). El walk-forward agrupado 2024+2025+2026 (6,802 partidos) si es significativo, IC95 [0.002536, 0.004759], pero 2 de sus 3 temporadas eligieron el metodo, asi que no promueve nada.'),

 ('cal_v4_historia_completa','mlb_totales_normal_v1','baseball','Over/Under','isotonic',
  '{"bins":50,"nota":"PAVA sobre 50 bins de conteo igual"}'::jsonb,
  '2000-01-01','2025-01-01','2025-01-01','2026-01-01',
  30705, 4016, 18047, 2356, 801,
  0.242237, 0.239263, 0.677741, 0.671332, 0.052778, 0.012502,
  0, true, false, false,
  'RECHAZADA. Se probo en los folds internos como exigio el dueno y perdio contra Platt en los dos: fold 1 Brier 0.241460 vs 0.241134, fold 2 0.239263 vs 0.238906. Mejora sobre identidad, si; pero no le gana a Platt, y Platt tiene 2 parametros contra ~20 bloques. No se adopta algo mas complejo que no mide mejor.'),

 ('cal_v4_historia_completa','nfl_totales_normal_v1','football','Over/Under','identity',
  '{}'::jsonb,
  '2000-01-01','2025-07-01','2025-07-01','2026-07-01',
  0, 0, 2343, 238, 37,
  0.226115, 0.226115, 0.643530, 0.643530, 0.045459, 0.045459,
  0, false, true, false,
  'IDENTIDAD por inconsistencia de Platt, no por falta de prueba: gana la temporada 2023 (0.238266->0.227650) y PIERDE la 2024 (0.232611->0.257187, con el ECE empeorando de 0.072559 a 0.171028). 1-1 y la derrota es mayor. NO APTO PARA LOCK: 238 partidos de holdout alcanzan para auditar, no para promover.'),

 ('cal_v4_historia_completa','nfl_totales_normal_v1','football','Over/Under','platt',
  '{"a":-0.45523965,"b":0.86923336,"convergio":true}'::jsonb,
  '2000-01-01','2024-07-01','2024-07-01','2025-07-01',
  5142, 522, 2343, 239, 47,
  0.232611, 0.257187, 0.658211, 0.710738, 0.072559, 0.171028,
  0, false, false, false,
  'RECHAZADO. Gano el fold de 2023 y perdio el de 2024 empeorando el Brier en 0.024576 y el ECE en 0.098469. Un calibrador que ayuda un ano y hace dano el siguiente no se adopta.');

-- FIN iss091. Reporte en shadow-patches/REPORTE_CALIBRACION_V4.md
