-- ISS257 — El veredicto lo gana el modelo QUE PUBLICA HOY.
--
-- DEFECTO MEDIDO (produccion wpiztubmmmzclhlprgpd, 2026-09-19):
--   public.v_evidencia_mercado_soccer calculaba `veredicto` leyendo SOLO `p`
--   (crossleague_v1, el prior). El modelo que de verdad publica la tarjeta,
--   soccer_canonical_v2 -- etiquetado en la propia vista como "el que publica
--   hoy" -- se calculaba en `evidencia_publicado` y despues se IGNORABA.
--
--   Resultado visible: 102 de 102 tarjetas de futbol mostraban el mercado
--   'ganador' con veredicto MEJOR_QUE_ADIVINAR_CONCLUYENTE, que el frontend
--   pinta como insignia VERDE "Validado con resultados reales"
--   (TEXTO_INSIGNIA[VEREDICTO_MEJOR] en
--   src/v2/components/soccer/EvidenciaMercadoSoccer.tsx), mientras el modelo
--   que produce ese numero tenia su propio IC95 CRUZANDO EL CERO:
--
--     1X2  crossleague_v1      n=198  IC95 [-0.0877, -0.0084]  -> MEJOR
--     1X2  soccer_canonical_v2 n= 66  IC95 [-0.1189, +0.0194]  -> SIN VEREDICTO
--
--   Es decir: la insignia "Validado" la ganaba un modelo que no publica.
--
-- POR QUE ES UN DEFECTO Y NO UNA DECISION DE DISENO:
--   La regla ya estaba escrita en esta misma base, en la funcion hermana
--   public.fn_evidencia_mercado, que degrada la evidencia del predecesor a
--   'veredicto_de_la_anterior' con la advertencia literal:
--     "Esto NO es el veredicto de la version que estas viendo.
--      La evidencia no se hereda"
--   y en el frontend, en LinajeEvidenciaVista ("la evidencia no se hereda...
--   el veredicto grande sigue siendo el de la version actual").
--   v_evidencia_mercado_soccer era la unica ruta que heredaba.
--
-- QUE CAMBIA (fail-closed, solo se APRIETA, nunca se afloja):
--   - MEJOR_QUE_ADIVINAR_CONCLUYENTE exige ahora que el IC95 del modelo QUE
--     PUBLICA quede entero por debajo de cero. Sin numeros propios: no hay
--     veredicto (no se hereda del prior).
--   - PEOR_QUE_ADIVINAR_CONCLUYENTE se mantiene si CUALQUIERA de los dos sale
--     concluyentemente peor: la advertencia mas fuerte siempre manda.
--   - 'total' no se toca: sigue RETIRADO con su texto propio.
--   - La explicacion deja de atribuir al que publica una evidencia ajena y
--     nombra los dos modelos con sus n reales.
--
-- EFECTO MEDIDO DEL PARCHE:
--   ganador : MEJOR_QUE_ADIVINAR_CONCLUYENTE -> SIN_VEREDICTO_MUESTRA_INSUFICIENTE
--             (insignia verde "Validado con resultados reales"
--              -> gris "Muestra insuficiente todavia")
--   btts    : sin cambio (ya era SIN_VEREDICTO_MUESTRA_INSUFICIENTE)
--   total   : sin cambio (SIN_VEREDICTO_CEREBRO_NUEVO, mercado retirado)
--
-- QUE **NO** CAMBIA -- comprobado antes de aplicar:
--   El unico consumidor de esta vista es public.v_tarjeta_soccer_v1_calculo,
--   que la agrega a `evidencia_por_mercado` y la PASA a la pantalla. Ningun
--   gate de publicacion ni de dinero lee `veredicto`. Por lo tanto este parche
--   NO apaga picks, NO reduce cobertura y NO cierra ningun deporte: solo
--   corrige lo que la tarjeta AFIRMA sobre su propia evidencia.
--
-- REVERSIBLE: shadow-patches/iss257/rollback_v_evidencia_mercado_soccer.sql
-- No borra objetos. CREATE OR REPLACE conserva columnas, orden, tipos y grants.

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
            ELSE jsonb_build_object('modelo', 'crossleague_v1', 'papel', 'prior que alimenta soccer_canonical_v2 en las 16 ligas domesticas; su evidencia NO valida al que publica', 'n', p.n_events, 'brier_modelo', round(p.brier_model, 4), 'brier_adivinando', round(p.brier_naive, 4), 'ic95_inferior', round(p.lower95, 4), 'ic95_superior', round(p.upper95, 4), 'accuracy_pct', round(p.leader_accuracy_pct, 1), 'gap_calibracion_pp', round(p.max_calibration_gap_pp, 1))
        END AS evidencia_prior,
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN jsonb_build_object('modelo', 'ninguno', 'papel', 'MERCADO RETIRADO: hoy no se publican altas y bajas de futbol', 'n', 0, 'brier_modelo', NULL::unknown, 'brier_adivinando', NULL::unknown, 'ic95_inferior', NULL::unknown, 'ic95_superior', NULL::unknown, 'accuracy_pct', NULL::unknown, 'nota', 'No hay modelo publicando este mercado. Se probaron los dos caminos sobre los mismos 152 partidos calificados y los dos pierden contra adivinar: p_over calibrado 0.5436 (IC95 0.0065 a 0.0808) y lambda mas Poisson 0.5424 (IC95 0.0057 a 0.0792).')
            ELSE jsonb_build_object('modelo', 'soccer_canonical_v2', 'papel', 'el que publica hoy: el veredicto es SUYO y lo tiene que ganar el solo', 'n', c.n_events, 'brier_modelo', round(c.brier_model, 4), 'brier_adivinando', round(c.brier_naive, 4), 'ic95_inferior', round(c.lower95, 4), 'ic95_superior', round(c.upper95, 4), 'accuracy_pct', round(c.leader_accuracy_pct, 1))
        END AS evidencia_publicado,
        -- ISS257: el veredicto lo gana QUIEN PUBLICA. La evidencia no se hereda.
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN 'SIN_VEREDICTO_CEREBRO_NUEVO'::text
            -- La advertencia mas fuerte siempre manda: si cualquiera de los dos
            -- sale concluyentemente peor que adivinar, se avisa.
            WHEN p.lower95 > 0::numeric OR c.lower95 > 0::numeric THEN 'PEOR_QUE_ADIVINAR_CONCLUYENTE'::text
            -- "Validado" SOLO si el modelo que publica lo demostro el solo.
            WHEN c.upper95 IS NOT NULL AND c.upper95 < 0::numeric THEN 'MEJOR_QUE_ADIVINAR_CONCLUYENTE'::text
            ELSE 'SIN_VEREDICTO_MUESTRA_INSUFICIENTE'::text
        END AS veredicto,
        CASE
            WHEN m.mercado_tarjeta = 'total'::text THEN 'El mercado de altas y bajas de futbol esta RETIRADO desde el 17 de septiembre de 2026. Se midieron los dos caminos posibles sobre los mismos 152 partidos ya calificados: el p_over guardado pasado por calibracion da Brier 0.5436 y la lambda del crossleague sumada con Poisson da 0.5424, contra 0.5 de adivinar, y en los dos casos el intervalo del 95% queda ENTERO por encima de cero. Los dos son concluyentemente peores que una moneda. La regla de la casa es que nada publicado puede ser concluyentemente peor que adivinar, asi que el mercado se retira en vez de maquillarse. El ganador y el ambos anotan no se tocan: su evidencia es otra y se mide aparte.'::text
            WHEN c.lower95 > 0::numeric THEN format('El modelo que publica hoy (soccer_canonical_v2) sale PEOR que adivinar sobre %s partidos reales, con el intervalo del 95%% entero por encima de cero. No es ruido.'::text, c.n_events)
            WHEN p.lower95 > 0::numeric THEN format('El prior que alimenta a este mercado (crossleague_v1) sale PEOR que adivinar sobre %s partidos reales, con el intervalo del 95%% entero por encima de cero. No es ruido.'::text, p.n_events)
            WHEN c.upper95 IS NOT NULL AND c.upper95 < 0::numeric THEN format('El modelo que publica hoy (soccer_canonical_v2) le gana al baseline sobre %s partidos reales, con su intervalo del 95%% entero por debajo de cero. El veredicto es suyo, medido con sus propios partidos.'::text, c.n_events)
            WHEN c.n_events IS NULL THEN 'El modelo que publica hoy todavia no tiene partidos calificados. Sin evidencia propia no se declara validado: la evidencia del prior no se hereda.'::text
            ELSE format('El modelo que publica hoy (soccer_canonical_v2) lleva %s partidos calificados y su intervalo del 95%% cruza el cero: todavia no se puede afirmar ni que le gana ni que le pierde a adivinar. El prior crossleague_v1 mide %s partidos, pero esa evidencia valida al prior, no al que publica: no se hereda.'::text, c.n_events, p.n_events)
        END AS explicacion,
    'El baseline es adivinar con las frecuencias base (1/3 cada resultado en 1X2, 50/50 en BTTS y Over/Under). Brier mas bajo es mejor.'::text AS como_leerlo,
    now() AS evaluado_at
   FROM m
     LEFT JOIN g p ON p.market = m.market AND p.model_version = 'crossleague_v1'::text
     LEFT JOIN g c ON c.market = m.market AND c.model_version = 'soccer_canonical_v2'::text;

comment on view public.v_evidencia_mercado_soccer is
  'ISS257: el veredicto lo gana el modelo que PUBLICA (soccer_canonical_v2), no el prior (crossleague_v1). La evidencia no se hereda. Fail-closed: sin IC95 propio entero por debajo de cero no se dice "validado".';
