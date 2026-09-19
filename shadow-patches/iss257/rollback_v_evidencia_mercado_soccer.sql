-- ROLLBACK EXACTO de ISS257.
-- Restaura public.v_evidencia_mercado_soccer a la definicion que estaba viva
-- en produccion (wpiztubmmmzclhlprgpd) antes del parche, capturada con
-- pg_get_viewdef(...,true) el 2026-09-19.
--
-- Efecto de correr esto: el veredicto de 'ganador' y 'btts' vuelve a leerse
-- del PRIOR (crossleague_v1) y 'ganador' vuelve a mostrarse como
-- MEJOR_QUE_ADIVINAR_CONCLUYENTE -> insignia verde "Validado con resultados
-- reales" en las tarjetas de futbol.

create or replace view public.v_evidencia_mercado_soccer as
 WITH g AS (
         SELECT model_learning_gate.market,
            model_learning_gate.model_version,
            model_learning_gate.n_events,
            model_learning_gate.brier_model,
            model_learning_gate.brier_naive,
            model_learning_gate.brier_vs_naive_diff AS diff,
            2::numeric * model_learning_gate.brier_vs_naive_diff - model_learning_gate.brier_vs_naive_upper95 AS lower95,
            model_learning_gate.brier_vs_naive_upper95 AS upper95,
            model_learning_gate.leader_accuracy_pct,
            model_learning_gate.max_calibration_gap_pp
           FROM v2.model_learning_gate
          WHERE model_learning_gate.scope = 'GLOBAL'::text AND model_learning_gate.brier_vs_naive_upper95 IS NOT NULL
        ), m(mercado_tarjeta, market) AS (
         VALUES ('ganador'::text,'1X2'::text), ('btts'::text,'BTTS'::text), ('total'::text,'Over/Under'::text)
        )
 SELECT m.mercado_tarjeta,
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN jsonb_build_object('modelo', 'crossleague_v1', 'papel', 'el cerebro de totales RETIRADO el 17 de septiembre por salir peor que adivinar', 'n', p.n_events, 'brier_modelo', round(p.brier_model, 4), 'brier_adivinando', round(p.brier_naive, 4), 'ic95_inferior', round(p.lower95, 4), 'ic95_superior', round(p.upper95, 4), 'accuracy_pct', round(p.leader_accuracy_pct, 1), 'gap_calibracion_pp', round(p.max_calibration_gap_pp, 1))
            ELSE jsonb_build_object('modelo', 'crossleague_v1', 'papel', 'prior que alimenta soccer_canonical_v2 en las 16 ligas domesticas', 'n', p.n_events, 'brier_modelo', round(p.brier_model, 4), 'brier_adivinando', round(p.brier_naive, 4), 'ic95_inferior', round(p.lower95, 4), 'ic95_superior', round(p.upper95, 4), 'accuracy_pct', round(p.leader_accuracy_pct, 1), 'gap_calibracion_pp', round(p.max_calibration_gap_pp, 1))
        END AS evidencia_prior,
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN jsonb_build_object('modelo', 'ninguno', 'papel', 'MERCADO RETIRADO: hoy no se publican altas y bajas de futbol', 'n', 0, 'brier_modelo', NULL::unknown, 'brier_adivinando', NULL::unknown, 'ic95_inferior', NULL::unknown, 'ic95_superior', NULL::unknown, 'accuracy_pct', NULL::unknown, 'nota', 'No hay modelo publicando este mercado. Se probaron los dos caminos sobre los mismos 152 partidos calificados y los dos pierden contra adivinar: p_over calibrado 0.5436 (IC95 0.0065 a 0.0808) y lambda mas Poisson 0.5424 (IC95 0.0057 a 0.0792).')
            ELSE jsonb_build_object('modelo', 'soccer_canonical_v2', 'papel', 'el que publica hoy', 'n', c.n_events, 'brier_modelo', round(c.brier_model, 4), 'brier_adivinando', round(c.brier_naive, 4), 'ic95_inferior', round(c.lower95, 4), 'ic95_superior', round(c.upper95, 4), 'accuracy_pct', round(c.leader_accuracy_pct, 1))
        END AS evidencia_publicado,
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN 'SIN_VEREDICTO_CEREBRO_NUEVO'::text
            WHEN p.lower95 > 0::numeric THEN 'PEOR_QUE_ADIVINAR_CONCLUYENTE'::text
            WHEN p.upper95 < 0::numeric THEN 'MEJOR_QUE_ADIVINAR_CONCLUYENTE'::text
            ELSE 'SIN_VEREDICTO_MUESTRA_INSUFICIENTE'::text
        END AS veredicto,
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN 'El mercado de altas y bajas de futbol esta RETIRADO desde el 17 de septiembre de 2026. Se midieron los dos caminos posibles sobre los mismos 152 partidos ya calificados: el p_over guardado pasado por calibracion da Brier 0.5436 y la lambda del crossleague sumada con Poisson da 0.5424, contra 0.5 de adivinar, y en los dos casos el intervalo del 95% queda ENTERO por encima de cero. Los dos son concluyentemente peores que una moneda. La regla de la casa es que nada publicado puede ser concluyentemente peor que adivinar, asi que el mercado se retira en vez de maquillarse. El ganador y el ambos anotan no se tocan: su evidencia es otra y se mide aparte.'::text
            WHEN p.lower95 > 0::numeric THEN format('Sobre %s partidos reales este mercado sale PEOR que adivinar, y el intervalo de confianza del 95%% esta entero por encima de cero. No es ruido.'::text, p.n_events)
            WHEN p.upper95 < 0::numeric THEN format('Sobre %s partidos reales este mercado supera al baseline con el intervalo de 95%% entero por debajo de cero.'::text, p.n_events)
            ELSE format('Sobre %s partidos el intervalo cruza el cero: todavia no se puede afirmar ni que gana ni que pierde contra adivinar.'::text, p.n_events)
        END AS explicacion,
    'El baseline es adivinar con las frecuencias base (1/3 cada resultado en 1X2, 50/50 en BTTS y Over/Under). Brier mas bajo es mejor.'::text AS como_leerlo,
    now() AS evaluado_at
   FROM m
     LEFT JOIN g p ON p.market = m.market AND p.model_version = 'crossleague_v1'::text
     LEFT JOIN g c ON c.market = m.market AND c.model_version = 'soccer_canonical_v2'::text;
