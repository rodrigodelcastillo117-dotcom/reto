-- baseline/v_super_pick.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
--
-- ULTIMA de las 14 vistas del cierre de decision que faltaba en Git. Antes de
-- este archivo, su unico "create" en el repo vivia DENTRO de un parche:
--     execute 'create or replace view public.v_super_pick as ' || replace(v,a,b)
-- o sea, armando el DDL a partir de una definicion LEIDA DE PRODUCCION. Mi
-- primer verificador la contaba como reproducible; no lo era.
--
-- =====================================================================
-- HALLAZGO MAS GRAVE QUE EL QUE YA HABIA REPORTADO EN ISS107
--
--   La probabilidad que esta vista MUESTRA al usuario es:
--       prob_pct = round(COALESCE(prob_observada, prob_declarada) * 100, 1)
--   prob_observada va PRIMERO. Y prob_observada viene de calibracion_mercado:
--       (ganados + 40 * avg(1.0 / momio_mercado)) / (n + 40)
--   O sea: cuando existe calibracion del segmento, la probabilidad publicada
--   NO es P_RETO. Es una mezcla bayesiana cuyo prior es la PROBABILIDAD
--   IMPLICITA DEL PRECIO.
--
--   El candado del dueno dice, textual: "Nunca sustituyas P_RETO con
--   implied/no-vig de DraftKings". Aqui la sustitucion no es un reemplazo
--   directo, es una mezcla, y por eso no se veia: el numero sigue
--   llamandose probabilidad. Pero el precio esta adentro del numero que el
--   usuario lee como probabilidad del modelo.
--
--   En ISS107 clasifique las 5 lineas de esta vista como "el precio autoriza,
--   selecciona y rankea". Es correcto y ademas INCOMPLETO: el precio tambien
--   esta DENTRO de la probabilidad mostrada. Eso es mas grave.
-- =====================================================================
--
-- OTRAS COSAS QUE HAY QUE SABER AL LEERLA
--
--  1) ev_real_pct NO es EV contra el precio. Es ROI historico encogido:
--        ev_real_pct = roi_real_pct * muestra / (muestra + 100)
--     El encogimiento hacia 0 con muestra chica es estadisticamente correcto
--     (regresion a la media) y la vista hasta se lo explica al usuario en
--     red_flags. Pero roi_real_pct se calcula con momio_mercado, asi que el
--     precio tambien esta adentro de ev_real_pct.
--
--  2) LAS 5 VIOLACIONES REGISTRADAS EN ISS107, con su linea:
--        apto = ev_real_pct > 0 AND roi_segmento > 0 AND confiable
--               AND NOT momio_inflado            -> el precio AUTORIZA
--        elegible_estrella exige ev_real_pct >= 20 -> el precio SELECCIONA
--        orden_estrella ORDER BY score_total, ev_real_pct  -> RANKEA
--        ORDER BY r.apto DESC, r.ev_real_pct DESC, r.score_total DESC
--                                                  -> rankea TODA la vista
--        tier: >= 20 'PICK DEL DIA', >= 8 'FUERTE', > 0 'SOLIDO',
--              else 'NO RECOMENDADO'              -> el precio ETIQUETA
--
--  3) LO QUE HACE EXCEPCIONALMENTE BIEN, y es lo mejor del sistema:
--     momio_inflado = desvio_vs_libro_pct > 3.0, y cuando se activa el texto
--     que ve el usuario es, textual:
--       "MOMIO INFLADO: la IA dijo X pero <casa> paga Y. La ventaja que
--        mostraba no existe a ese precio."
--     Y si no hay lectura de casa:
--       "MOMIO SIN VERIFICAR: el momio lo puso la IA y nadie lo confirmo."
--     Y si el segmento pierde dinero:
--       "ESTE TIPO DE PICK PIERDE DINERO: N apuestas con ROI real de X%."
--     Eso es honestidad hacia el usuario, escrita en el producto. No se toca.
--
--  4) economic_eligibility_v1 se llama con model_version = NULL HARDCODEADO y
--     mercado = 'Moneyline' fijo, sin importar el mercado real del pick. O sea
--     la puerta economica se consulta con una llave incompleta y con el
--     mercado equivocado. Queda reportado.
--
--  5) apto_para_mostrar = apto AND economic_eligibility_v1(...). Es decir la
--     elegibilidad ECONOMICA compuerta si el pick se MUESTRA, no solo cuanto
--     se apuesta. Eso es precio decidiendo visibilidad.
--
-- NO SE CORRIGE NADA AQUI. Cambiar cualquiera de los puntos 1, 2, 4 o 5
-- altera que picks existen, con que probabilidad y en que orden: es cutover de
-- modelo y seleccion, congelado hasta autorizacion del dueno.
-- =====================================================================

create or replace view public.v_super_pick as
 SELECT pick_id,
    espn_event_id,
    partido,
    liga,
    deporte,
    mercado,
    pick_desc,
    momio,
    match_date,
    clasificacion,
    confianza_ai,
    razonamiento,
    prob_pct,
    ev_real_pct,
    ev_declarado_pct,
    muestra_calibracion,
    analisis_confirma,
    perfil_respalda,
    wr_historico,
    muestra_historica,
    score_total,
    tier,
    apto_para_mostrar,
    razones_positivas,
    red_flags,
    momio_declarado_ia,
    momio_libro,
    momio_verificado,
    bookmaker,
    momio_leido_en,
    desvio_vs_libro_pct
   FROM ( WITH base AS (
                 SELECT md5((((v.espn_event_id || '|'::text) || COALESCE(v.pick_nombre, ''::text)) || '|'::text) || COALESCE(v.mercado, ''::text))::uuid AS pick_id,
                    v.espn_event_id,
                    (v.home || ' vs '::text) || v.away AS partido,
                    v.liga,
                    COALESCE(deporte_por_liga_estricto(v.liga), '⚽ Fútbol'::text) AS deporte,
                    v.mercado,
                    COALESCE(v.pick_nombre, v.pick_desc) AS pick_desc,
                    v.momio_mercado AS momio_ai,
                    v.probabilidad_real AS prob_declarada,
                    v.ev_numerico AS ev_declarado_pct,
                    v.confianza AS confianza_ai,
                    v.clasificacion,
                    v.kelly_pct,
                    COALESCE(v.razon, v.resumen) AS razonamiento,
                    ls.game_date AS match_date,
                    mercado_normalizado((COALESCE(v.mercado, ''::text) || ' '::text) || COALESCE(v.pick_nombre, ''::text)) AS mercado_norm
                   FROM picks_recomendados_hoy v
                     JOIN live_scores ls ON ls.espn_event_id = v.espn_event_id
                  WHERE ls.game_date >= (now() - '02:00:00'::interval) AND ls.game_date <= (now() + '36:00:00'::interval) AND v.momio_mercado IS NOT NULL AND v.momio_mercado > 1.01
                ), conmomio AS (
                 SELECT b.pick_id,
                    b.espn_event_id,
                    b.partido,
                    b.liga,
                    b.deporte,
                    b.mercado,
                    b.pick_desc,
                    b.momio_ai,
                    b.prob_declarada,
                    b.ev_declarado_pct,
                    b.confianza_ai,
                    b.clasificacion,
                    b.kelly_pct,
                    b.razonamiento,
                    b.match_date,
                    b.mercado_norm,
                    lb.momio_libro,
                    lb.bookmaker,
                    lb.momio_leido_en,
                    COALESCE(lb.momio_libro, b.momio_ai) AS momio_usado,
                    lb.momio_libro IS NOT NULL AS momio_verificado,
                        CASE
                            WHEN lb.momio_libro IS NOT NULL THEN round(100.0 * (b.momio_ai - lb.momio_libro) / lb.momio_libro, 1)
                            ELSE NULL::numeric
                        END AS desvio_vs_libro_pct
                   FROM base b
                     LEFT JOIN v_pick_momio_libro lb ON lb.espn_event_id = b.espn_event_id AND lb.pick_desc = b.pick_desc AND lb.momio_libro IS NOT NULL
                ), calc AS (
                 SELECT c.pick_id,
                    c.espn_event_id,
                    c.partido,
                    c.liga,
                    c.deporte,
                    c.mercado,
                    c.pick_desc,
                    c.momio_ai,
                    c.prob_declarada,
                    c.ev_declarado_pct,
                    c.confianza_ai,
                    c.clasificacion,
                    c.kelly_pct,
                    c.razonamiento,
                    c.match_date,
                    c.mercado_norm,
                    c.momio_libro,
                    c.bookmaker,
                    c.momio_leido_en,
                    c.momio_usado,
                    c.momio_verificado,
                    c.desvio_vs_libro_pct,
                    rango_de_momio(c.momio_usado) AS rango_momio,
                    k.muestra AS muestra_calibracion,
                    k.roi_real_pct AS roi_segmento,
                    k.wr_real AS wr_segmento,
                    k.confiable,
                    k.prob_observada,
                        CASE
                            WHEN k.muestra IS NOT NULL THEN round(k.roi_real_pct * k.muestra::numeric / (k.muestra::numeric + 100.0), 2)
                            ELSE NULL::numeric
                        END AS ev_real_pct,
                    (EXISTS ( SELECT 1
                           FROM oraculo_picks_tracking o
                          WHERE o.espn_event_id = c.espn_event_id AND lower(COALESCE(o.pick_nombre, ''::text)) = lower(c.pick_desc))) AS analisis_confirma
                   FROM conmomio c
                     LEFT JOIN calibracion_mercado k ON k.mercado_norm = c.mercado_norm AND k.rango_momio = rango_de_momio(c.momio_usado)
                ), puntuado AS (
                 SELECT c.pick_id,
                    c.espn_event_id,
                    c.partido,
                    c.liga,
                    c.deporte,
                    c.mercado,
                    c.pick_desc,
                    c.momio_ai,
                    c.prob_declarada,
                    c.ev_declarado_pct,
                    c.confianza_ai,
                    c.clasificacion,
                    c.kelly_pct,
                    c.razonamiento,
                    c.match_date,
                    c.mercado_norm,
                    c.momio_libro,
                    c.bookmaker,
                    c.momio_leido_en,
                    c.momio_usado,
                    c.momio_verificado,
                    c.desvio_vs_libro_pct,
                    c.rango_momio,
                    c.muestra_calibracion,
                    c.roi_segmento,
                    c.wr_segmento,
                    c.confiable,
                    c.prob_observada,
                    c.ev_real_pct,
                    c.analisis_confirma,
                    round(COALESCE(c.prob_observada, c.prob_declarada) * 100::numeric, 1) AS prob_pct,
                    COALESCE(c.roi_segmento, 0::numeric) > 0::numeric AND c.confiable AS perfil_respalda,
                    COALESCE(c.desvio_vs_libro_pct, 0::numeric) > 3.0 AS momio_inflado,
                    LEAST(100::numeric, GREATEST(0::numeric, round(LEAST(60::numeric, GREATEST(0::numeric, COALESCE(c.ev_real_pct, 0::numeric) * 2.5)) + 25.0 * COALESCE(c.muestra_calibracion, 0)::numeric / (COALESCE(c.muestra_calibracion, 0)::numeric + 200.0) +
                        CASE
                            WHEN c.analisis_confirma THEN 15
                            ELSE 0
                        END::numeric +
                        CASE
                            WHEN c.momio_verificado THEN 10
                            ELSE 0
                        END::numeric)))::integer AS score_total
                   FROM calc c
                ), rankeado AS (
                 SELECT p.pick_id,
                    p.espn_event_id,
                    p.partido,
                    p.liga,
                    p.deporte,
                    p.mercado,
                    p.pick_desc,
                    p.momio_ai,
                    p.prob_declarada,
                    p.ev_declarado_pct,
                    p.confianza_ai,
                    p.clasificacion,
                    p.kelly_pct,
                    p.razonamiento,
                    p.match_date,
                    p.mercado_norm,
                    p.momio_libro,
                    p.bookmaker,
                    p.momio_leido_en,
                    p.momio_usado,
                    p.momio_verificado,
                    p.desvio_vs_libro_pct,
                    p.rango_momio,
                    p.muestra_calibracion,
                    p.roi_segmento,
                    p.wr_segmento,
                    p.confiable,
                    p.prob_observada,
                    p.ev_real_pct,
                    p.analisis_confirma,
                    p.prob_pct,
                    p.perfil_respalda,
                    p.momio_inflado,
                    p.score_total,
                    COALESCE(p.ev_real_pct, '-1'::integer::numeric) > 0::numeric AND COALESCE(p.roi_segmento, '-1'::integer::numeric) > 0::numeric AND p.confiable AND NOT p.momio_inflado AS apto,
                    row_number() OVER (PARTITION BY (
                        CASE
                            WHEN COALESCE(p.ev_real_pct, '-1'::integer::numeric) >= 20::numeric AND p.momio_verificado AND NOT p.momio_inflado AND COALESCE(p.roi_segmento, '-1'::integer::numeric) > 0::numeric AND p.confiable THEN 1
                            ELSE 0
                        END) ORDER BY p.score_total DESC, p.ev_real_pct DESC NULLS LAST, p.muestra_calibracion DESC NULLS LAST, p.prob_pct DESC NULLS LAST, p.match_date) AS orden_estrella,
                    COALESCE(p.ev_real_pct, '-1'::integer::numeric) >= 20::numeric AND p.momio_verificado AND NOT p.momio_inflado AND COALESCE(p.roi_segmento, '-1'::integer::numeric) > 0::numeric AND p.confiable AS elegible_estrella
                   FROM puntuado p
                )
         SELECT r.pick_id,
            r.espn_event_id,
            r.partido,
            r.liga,
            r.deporte,
            r.mercado,
            r.pick_desc,
            r.momio_usado AS momio,
            r.match_date,
            r.clasificacion,
            r.confianza_ai,
            r.razonamiento,
            r.prob_pct,
            r.ev_real_pct,
            NULL::numeric AS ev_declarado_pct,
            r.muestra_calibracion,
            r.analisis_confirma,
            r.perfil_respalda,
            r.wr_segmento AS wr_historico,
            r.muestra_calibracion AS muestra_historica,
            r.score_total,
                CASE
                    WHEN r.momio_inflado THEN 'NO RECOMENDADO'::text
                    WHEN r.elegible_estrella AND r.orden_estrella = 1 THEN 'PICK DEL DÍA 🔥'::text
                    WHEN COALESCE(r.ev_real_pct, '-1'::integer::numeric) >= 8::numeric THEN 'FUERTE'::text
                    WHEN COALESCE(r.ev_real_pct, '-1'::integer::numeric) > 0::numeric THEN 'SÓLIDO'::text
                    ELSE 'NO RECOMENDADO'::text
                END AS tier,
            r.apto AND ((economic_eligibility_v1(jsonb_build_object('deporte', deporte_registry(r.deporte), 'mercado', 'Moneyline', 'fuente', 'motor_picks', 'model_version', NULL::text)) ->> 'eligible'::text)::boolean) AS apto_para_mostrar,
                CASE
                    WHEN (economic_eligibility_v1(jsonb_build_object('deporte', deporte_registry(r.deporte), 'mercado', 'Moneyline', 'fuente', 'motor_picks', 'model_version', NULL::text)) ->> 'eligible'::text)::boolean THEN (decision_pick_v1(deporte_registry(r.deporte), 'Moneyline'::text, 'motor_picks'::text, NULL::text, r.prob_pct, r.momio_usado, 0::numeric, 5.0) ->> 'kelly_pct'::text)::numeric
                    ELSE 0::numeric
                END AS kelly_pct_sugerido,
            array_remove(ARRAY[
                CASE
                    WHEN r.momio_verificado THEN ((('Momio verificado contra '::text || r.bookmaker) || ' ('::text) || to_char((r.momio_leido_en AT TIME ZONE 'America/Mexico_City'::text), 'HH24:MI'::text)) || ' hrs)'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN r.roi_segmento > 0::numeric THEN ((((((('En '::text || r.muestra_calibracion) || ' apuestas de este tipo ('::text) || r.mercado_norm) || ' a momio '::text) || r.rango_momio) || '), el sistema lleva ROI real de +'::text) || r.roi_segmento) || '%'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN r.wr_segmento IS NOT NULL THEN ('Acierto histórico del segmento: '::text || r.wr_segmento) || '%'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN r.analisis_confirma THEN 'Dos fuentes independientes coinciden'::text
                    ELSE NULL::text
                END, NULL::text], NULL::text) AS razones_positivas,
            array_remove(ARRAY[
                CASE
                    WHEN r.momio_inflado THEN ((((('MOMIO INFLADO: la IA dijo '::text || to_char(r.momio_ai, 'FM990.00'::text)) || ' pero '::text) || r.bookmaker) || ' paga '::text) || to_char(r.momio_libro, 'FM990.00'::text)) || '. La ventaja que mostraba no existe a ese precio.'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN NOT r.momio_verificado THEN 'MOMIO SIN VERIFICAR: no hay lectura de casa de apuestas para este partido. El momio lo puso la IA y nadie lo confirmó.'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN r.muestra_calibracion IS NULL THEN 'SIN HISTORIAL: nunca se ha medido este mercado en este rango de momio.'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN NOT COALESCE(r.confiable, false) AND r.muestra_calibracion IS NOT NULL THEN ('Muestra insuficiente ('::text || r.muestra_calibracion) || '): no alcanza para confiar.'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN COALESCE(r.roi_segmento, 0::numeric) <= 0::numeric AND r.confiable THEN ((('ESTE TIPO DE PICK PIERDE DINERO: '::text || r.muestra_calibracion) || ' apuestas con ROI real de '::text) || r.roi_segmento) || '%.'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN r.muestra_calibracion IS NOT NULL AND r.muestra_calibracion < 250 THEN ('Muestra de '::text || r.muestra_calibracion) || ': el ROI mostrado ya viene reducido porque números así regresan a la media.'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN NOT r.analisis_confirma THEN 'Una sola fuente lo recomienda.'::text
                    ELSE NULL::text
                END,
                CASE
                    WHEN r.elegible_estrella AND r.orden_estrella > 1 THEN ('Mismo perfil que el pick del día, pero quedó '::text || r.orden_estrella) || 'º al desempatar: el EV que se muestra es el del segmento, no exclusivo de este partido.'::text
                    ELSE NULL::text
                END], NULL::text) AS red_flags,
            r.momio_ai AS momio_declarado_ia,
            r.momio_libro,
            r.momio_verificado,
            r.bookmaker,
            r.momio_leido_en,
            r.desvio_vs_libro_pct
           FROM rankeado r
          ORDER BY r.apto DESC, r.ev_real_pct DESC NULLS LAST, r.score_total DESC) _q;
