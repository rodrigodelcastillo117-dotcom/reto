-- =====================================================================
-- ISS116  CLASIFICACION DE v_picks_futbol_calc  (AUDIT_NO_PASS 5647363543)
-- =====================================================================
-- El dueno pidio cuatro cosas. Respuesta corta primero:
--   el SELECTOR upstream esta LIMPIO. La violacion esta en UNA columna de
--   esta vista, y es peor de lo que parece por una razon que no es la obvia.
--
-- ME CORRIJO ANTES DE AFIRMAR NADA
--   Al ver "ORDER BY score_valor DESC" en picks_premium conclui que el precio
--   elegia el lado y el orden. ESTABA MAL. En picks_premium:
--     score_valor = round(probabilidad - CASE mercado
--                           WHEN 'Moneyline' THEN 33.3 ELSE 50.0 END, 2)
--   Es probabilidad SOBRE LA BASE DEL AZAR. Ruta de modelo, permitida, y es
--   exactamente el patron que mi propia prueba negativa T8 protege.
--
-- 1) CADENA DE ORIGEN
--      v_analisis_fut_completo   probabilidad = mk->>'probabilidad' del modelo
--        -> picks_premium        selecciona y ordena por prob - base_azar
--        -> v_picks_futbol_calc  recorta ventana y republica
--
-- 2) IDENTIDAD, LINAJE, TEMPORALIDAD
--      espn_event_id presente; mercado y pick semanticos; fecha del evento.
--      probabilidad NO esta contaminada por precio: no aparece en
--      p_reto_contaminado en ningun eslabon de la cadena.
--      PERO no hay model_version, ni calibration_version, ni decision_time, ni
--      identidad de snapshot en NINGUN punto de la cadena. Es el mismo
--      SIN_MODEL_VERSION de siempre.
--
-- 3) SEMANTICA DE SELECCION Y ORDEN  (la pregunta 3 del dueno)
--      picks_premium:
--        row_number() PARTITION BY fixture_id ORDER BY score_valor DESC,
--                     muestra_historica DESC, mercado, pick
--        WHERE rn <= 2 AND score_valor > 0
--        ORDER BY score_valor DESC, muestra_historica DESC, fecha
--      Todo eso con score_valor = prob - base_azar. ELEGIBILIDAD, SELECCION y
--      ORDEN son de MODELO. El precio no entra. Eso queda PROBADO.
--      Filtros adicionales, todos no-economicos: probabilidad entre 33 y 78,
--      respaldo_confiable, muestra_historica >= 300, |sesgo| <= 4,
--      ligas_bloqueadas, fuera amistosos y pretemporada, fuera el fallback
--      lam 1.35/1.35.
--
--      CUARENTENA: se aplica EN ORIGEN, dos veces. En picks_premium
--        WHERE NOT pick_en_cuarentena('soccer','Over/Under', pick)
--      y otra vez en v_picks_futbol_calc. No es contencion de React: el
--      backend ya excluye el mercado en cuarentena antes de publicar.
--
-- 4) LA VIOLACION REAL, Y POR QUE ES PEOR DE LO QUE PARECE
--      v_picks_futbol_calc REDEFINE score_valor:
--        round(p.probabilidad - 100.0 / NULLIF(p.momio_mercado, 0), 2)
--      Misma columna, mismo nombre, significado OPUESTO: arriba es ventaja
--      contra el azar, aqui es ventaja contra el precio.
--
--      Medido en produccion el 2026-09-12, 44 filas:
--        39 de 44 (89 %) quedan con score_valor = NULL, porque no hay
--           momio_mercado. La redefinicion por precio BORRA el score del
--           modelo en casi todas las filas que el frontend pinta.
--        de las 5 comparables: divergencia promedio 4.77 pp, maxima 10.79 pp,
--           y UNA cambia de signo.
--        las 44 son apostable=true y tienen respaldo ALTA o MEDIA.
--
--      O sea el dano principal no es que el orden se incline: es que el 89 %
--      de las filas pierden su score de modelo y cualquier consumidor que
--      ordene por score_valor ordena por disponibilidad de momio.
--
-- CORRECCION APLICADA (autorizada por la Decision 2 del dueno, punto 2 de su
-- orden autonoma: "remove price/implied probability from P_RETO and canonical
-- pick/ordering paths"). Es estrecha, reversible y NO toca probabilidad ni
-- seleccion ni conteo de filas:
--   score_valor  pasa a ser el de picks_premium, tal cual (prob - base_azar)
--   desacuerdo_vs_precio_pp  columna NUEVA y con nombre honesto, que lleva el
--                            prob - 100/momio que antes se llamaba score_valor.
--                            El precio puede mostrarse como contexto; lo que
--                            no puede es disfrazarse de score del modelo.
--
-- NO SE REVOCA EL SELECT de esta vista: el dueno lo prohibio explicitamente
-- mientras el frontend la siga consumiendo.
-- =====================================================================

create or replace view public.v_picks_futbol_calc as
 SELECT espn_event_id,
    liga,
    partido,
    fecha,
    hora_cdmx,
    mercado,
    pick,
    probabilidad,
    momio_justo,
    momio_mercado,
    bookmaker,
    ev,
    precio_verificado,
    score_valor,
    nivel,
    muestra_historica,
    acierto_historico,
    error_historico,
    marcador_probable,
    fundamento,
    respaldo_modelo,
    momio_minimo_aceptable,
    apostable,
    -- ISS116: columna NUEVA, al final a proposito. Postgres no permite insertar
    -- una columna en medio de una vista existente, y ademas conviene: las
    -- posiciones que ya consume el frontend no se mueven.
    desacuerdo_vs_precio_pp
   FROM ( SELECT p.espn_event_id,
            p.liga,
            p.partido,
            p.fecha,
            p.hora_cdmx,
            p.mercado,
            p.pick,
            p.probabilidad,
            p.momio_justo,
            p.momio_mercado,
            p.bookmaker,
            NULL::numeric AS ev,
            p.precio_verificado,
            -- ISS116: score de MODELO, pasado tal cual desde picks_premium.
            -- Antes aqui se recalculaba como probabilidad - 100/momio_mercado,
            -- lo que dejaba 39 de 44 filas en NULL y una con el signo volteado.
            p.score_valor,
            -- ISS116: el desacuerdo con el precio existe, se muestra, y se
            -- llama por su nombre. Contexto informativo, nunca score.
            round(p.probabilidad - 100.0 / NULLIF(p.momio_mercado, 0::numeric), 2) AS desacuerdo_vs_precio_pp,
            p.nivel,
            p.muestra_historica,
            p.acierto_historico,
            p.error_historico,
            p.marcador_probable,
            p.fundamento,
                CASE
                    WHEN p.lam_h IS NULL OR p.lam_a IS NULL THEN 'SIN_MODELO'::text
                    WHEN round(p.lam_h, 2) = 1.35 AND round(p.lam_a, 2) = 1.35 THEN 'FALLBACK'::text
                    WHEN p.muestra_modelo IS NULL THEN 'SIN_MODELO'::text
                    WHEN p.muestra_modelo >= 12 THEN 'ALTA'::text
                    WHEN p.muestra_modelo >= 6 THEN 'MEDIA'::text
                    ELSE 'BAJA'::text
                END AS respaldo_modelo,
            round(p.momio_justo * 1.06, 2) AS momio_minimo_aceptable,
            p.probabilidad IS NOT NULL AND p.probabilidad >
                CASE
                    WHEN p.mercado = 'Moneyline'::text THEN 33.3
                    ELSE 50.0
                END AS apostable
           FROM picks_premium p
          WHERE p.fecha >= now() AND p.fecha <= (now() + '48:00:00'::interval) AND p.probabilidad >= 52::numeric AND p.probabilidad <= 80::numeric AND NOT (round(COALESCE(p.lam_h, 0::numeric), 2) = 1.35 AND round(COALESCE(p.lam_a, 0::numeric), 2) = 1.35) AND p.liga !~~* '%amistoso%'::text AND p.liga !~~* '%friendly%'::text AND p.liga !~~* '%pretemporada%'::text) _pool
  WHERE NOT pick_en_cuarentena('soccer'::text, 'Over/Under'::text, pick);

comment on view public.v_picks_futbol_calc is
'ISS116. Soccer, ventana 48h. SELECCION Y ORDEN SON DE MODELO: picks_premium elige por probabilidad sobre la base del azar, no por precio. Cuarentena aplicada en origen. score_valor es el del modelo; el desacuerdo con el precio vive en desacuerdo_vs_precio_pp, con su nombre. NO es todavia el contrato canonico de Soccer: a toda la cadena le falta model_version, calibration_version y decision_time.';
